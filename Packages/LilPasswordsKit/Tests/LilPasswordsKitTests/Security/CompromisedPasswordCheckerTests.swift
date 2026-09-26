import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct CompromisedPasswordCheckerTests {
  // SHA-1("password123") = CBFDAC6008F9CAB4083784CBD1874F76618D2A97 — a real, extremely commonly
  // pwned password, prefix "CBFDA", suffix "C6008F9CAB4083784CBD1874F76618D2A97".
  private static let pwnedPrefix = "CBFDA"
  private static let pwnedSuffix = "C6008F9CAB4083784CBD1874F76618D2A97"

  // SHA-1("Correct-Horse-Battery-Staple-42!") = 5F36B84CBF3335341EC1D1A8D27E203670D678AF — a
  // password never included in any stubbed response below, so it always resolves "not compromised".
  private static let cleanPrefix = "5F36B"

  private static func rangeResponse(for prefix: String) -> (HTTPURLResponse, Data) {
    var body = ""
    if prefix == pwnedPrefix {
      body += "\(pwnedSuffix):3722468\r\n"
    }
    // A couple of padding-shaped lines (851-2458: `Add-Padding: true`), which a real response
    // would also include and which `parseSuffixes` must tolerate without misinterpreting them as
    // a match for anything callers actually asked about.
    body += "0000000000000000000000000000000000000000:0\r\n"
    body += "1111111111111111111111111111111111111111:0\r\n"
    let url = URL(string: "https://api.pwnedpasswords.com/range/\(prefix)")!
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    return (response, Data(body.utf8))
  }

  private static func makeChecker(
    requestedPrefixes: RequestedPrefixesBox = RequestedPrefixesBox(),
    statusCode: Int = 200
  ) -> CompromisedPasswordChecker {
    let session = StubURLProtocol.makeSession { request in
      #expect(request.url?.scheme == "https")
      #expect(request.value(forHTTPHeaderField: "Add-Padding") == "true")
      let prefix = request.url?.lastPathComponent ?? ""
      requestedPrefixes.append(prefix)
      if statusCode != 200 {
        let url = request.url!
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (response, Data())
      }
      return rangeResponse(for: prefix)
    }
    return CompromisedPasswordChecker(session: session, minimumRequestInterval: 0)
  }

  /// A tiny `Sendable` box so the stub closure above can record which prefixes it was asked
  /// for, and the test can assert on that afterwards.
  final class RequestedPrefixesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) {
      lock.lock()
      values.append(value)
      lock.unlock()
    }
    var all: [String] {
      lock.lock()
      defer { lock.unlock() }
      return values
    }
  }

  @Test func flagsAKnownPwnedPassword() async {
    let checker = Self.makeChecker()
    let ids = await checker.check([
      CompromisedPasswordChecker.Input(id: "leaked", password: "password123")
    ])
    #expect(ids == ["leaked"])
  }

  @Test func doesNotFlagAPasswordAbsentFromTheRangeResponse() async {
    let checker = Self.makeChecker()
    let ids = await checker.check([
      CompromisedPasswordChecker.Input(id: "safe", password: "Correct-Horse-Battery-Staple-42!")
    ])
    #expect(ids.isEmpty)
  }

  @Test func onlySendsTheFiveCharacterPrefixNeverTheFullHashOrPassword() async {
    let requested = RequestedPrefixesBox()
    let checker = Self.makeChecker(requestedPrefixes: requested)
    _ = await checker.check([
      CompromisedPasswordChecker.Input(id: "leaked", password: "password123")
    ])
    // `pwnedPrefix` is exactly 5 hex characters — the request the stub actually saw carried
    // nothing more identifying than that, never the remaining 35 hash characters or the password.
    #expect(requested.all == [Self.pwnedPrefix])
    #expect(Self.pwnedPrefix.count == 5)
  }

  @Test func coalescesRepeatedPasswordsIntoOneRequest() async {
    let requested = RequestedPrefixesBox()
    let checker = Self.makeChecker(requestedPrefixes: requested)
    let ids = await checker.check([
      CompromisedPasswordChecker.Input(id: "a", password: "password123"),
      CompromisedPasswordChecker.Input(id: "b", password: "password123"),
    ])
    #expect(ids == ["a", "b"])
    #expect(requested.all.count == 1)
  }

  @Test func cachesAcrossCallsWithoutASecondRequest() async {
    let requested = RequestedPrefixesBox()
    let checker = Self.makeChecker(requestedPrefixes: requested)
    _ = await checker.check([CompromisedPasswordChecker.Input(id: "a", password: "password123")])
    _ = await checker.check([CompromisedPasswordChecker.Input(id: "b", password: "password123")])
    #expect(requested.all.count == 1)
  }

  @Test func checksMultipleDifferentPasswordsInOneCall() async {
    let ids = await Self.makeChecker().check([
      CompromisedPasswordChecker.Input(id: "leaked", password: "password123"),
      CompromisedPasswordChecker.Input(id: "safe", password: "Correct-Horse-Battery-Staple-42!"),
    ])
    #expect(ids == ["leaked"])
  }

  @Test func treatsANetworkFailureAsNotCompromisedRatherThanThrowing() async {
    let checker = Self.makeChecker(statusCode: 503)
    let ids = await checker.check([
      CompromisedPasswordChecker.Input(id: "unknown", password: "password123")
    ])
    #expect(ids.isEmpty)
  }

  @Test func ignoresEmptyPasswords() async {
    let ids = await Self.makeChecker().check([
      CompromisedPasswordChecker.Input(id: "empty", password: "")
    ])
    #expect(ids.isEmpty)
  }

  @Test func parseSuffixesIgnoresMalformedLines() {
    let body = "ABCDEF0123456789ABCDEF0123456789ABCDEF01:5\r\nnotaline\r\n\r\n"
    let suffixes = CompromisedPasswordChecker.parseSuffixes(fromResponseBody: body)
    #expect(suffixes == ["ABCDEF0123456789ABCDEF0123456789ABCDEF01"])
  }

  @Test func sha1HexMatchesTheKnownDigest() {
    #expect(CompromisedPasswordChecker.sha1Hex("password123") == "\(Self.pwnedPrefix)\(Self.pwnedSuffix)")
  }
}
