import CryptoKit
import Foundation

/// Checks passwords against Have I Been Pwned's Pwned Passwords **range API** using
/// k-anonymity, so a password never leaves the device: only the first 5 hex characters of its
/// SHA-1 hash are sent, HIBP returns every known suffix sharing that prefix (with `Add-Padding:
/// true`, a deliberately noisy-sized response so an eavesdropper can't infer the true match count
/// from response size alone), and the exact match is found locally.
///
/// Opt-in (851-2458), off by default (``AppSettings/detectCompromisedPasswords``), and meant to
/// run only in the app process — never `LilPasswordsAgent` — and only while the vault is unlocked
/// and its plaintext passwords are already in memory; see `docs/adr/0001-storage-and-process-model.md`.
///
/// An `actor` so its cache and last-request timestamp (the rate limit) are safe to touch from
/// concurrent callers without a separate lock, and so every request happens one at a time — HIBP
/// asks integrations not to hammer the range endpoint, and hashes sharing a prefix are coalesced
/// into a single request per ``check(_:)`` call regardless.
public actor CompromisedPasswordChecker {
  /// One password to check, keyed by a caller-chosen, `Sendable` id (typically a
  /// `PasswordItem.id`) so results can be matched back up without this type depending on
  /// `PasswordItem`.
  public struct Input<ID: Hashable & Sendable>: Sendable {
    public let id: ID
    public let password: String

    public init(id: ID, password: String) {
      self.id = id
      self.password = password
    }
  }

  /// Base URL of the Pwned Passwords range API. A `var`, not a `let`, only so tests can point it
  /// at nothing meaningful — the stub `URLProtocol` intercepts every request regardless of host,
  /// but keeping this overridable documents that the exact endpoint isn't load-bearing for tests.
  private let rangeAPIBaseURL: URL
  private let session: URLSession

  /// Minimum spacing enforced between outgoing requests — a simple, sequential rate limit. HIBP's
  /// range API doesn't publish a hard quota, but this keeps a vault with hundreds of unique
  /// password prefixes from firing a burst of near-simultaneous requests.
  private let minimumRequestInterval: TimeInterval
  private var lastRequestFinishedAt: ContinuousClock.Instant?
  private let clock = ContinuousClock()

  /// In-memory-only cache from a password's **full** SHA-1 hex digest to whether it was found in
  /// the range response for its prefix — never the plaintext password, and never written to disk,
  /// per 851-2458 ("cache results per password hash... never plaintext on disk"). Cleared when
  /// the checker itself is deallocated, i.e. at the latest when the app quits or the vault locks
  /// and whatever owns this checker is torn down with it.
  private var resultCache: [String: Bool] = [:]

  /// - Parameters:
  ///   - session: Injected so tests can stub every request with `URLProtocol` and never touch the
  ///     network (851-2458). Defaults to an ephemeral session (no cookies, no shared cache) — this
  ///     checker only ever sends a 5-character hash prefix, but there's no reason to let HIBP set
  ///     a cookie or to persist its responses to disk.
  ///   - minimumRequestInterval: See ``minimumRequestInterval``.
  public init(
    session: URLSession = CompromisedPasswordChecker.makeDefaultSession(),
    rangeAPIBaseURL: URL = URL(string: "https://api.pwnedpasswords.com/range/")!,
    minimumRequestInterval: TimeInterval = 1.5
  ) {
    self.session = session
    self.rangeAPIBaseURL = rangeAPIBaseURL
    self.minimumRequestInterval = minimumRequestInterval
  }

  public static func makeDefaultSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
  }

  /// Checks every password in `inputs` and returns the ids whose password HIBP confirms has
  /// appeared in a known data leak.
  ///
  /// Failures are swallowed per-prefix (offline, timeout, non-200 response, malformed body): an
  /// id whose lookup couldn't be completed is simply omitted from the result rather than
  /// surfacing an error, since the Security view's job is to report what it positively knows,
  /// not to distinguish "confirmed clean" from "couldn't check right now". Duplicate passwords
  /// (including a password already resolved in a previous call, so already in ``resultCache``)
  /// never trigger more than one request per unique 5-character prefix.
  public func check<ID: Hashable & Sendable>(_ inputs: [Input<ID>]) async -> Set<ID> {
    // Group by full hash first so a password repeated across several items (already flagged as
    // "Reused" elsewhere) only ever needs one lookup, cached or not.
    var idsByHash: [String: [ID]] = [:]
    for input in inputs where !input.password.isEmpty {
      let hash = Self.sha1Hex(input.password)
      idsByHash[hash, default: []].append(input.id)
    }

    var compromisedHashes = Set<String>()
    var hashesNeedingLookup: [String] = []
    for hash in idsByHash.keys {
      if let cached = resultCache[hash] {
        if cached { compromisedHashes.insert(hash) }
      } else {
        hashesNeedingLookup.append(hash)
      }
    }

    // One HIBP request per unique 5-character prefix among the hashes we don't already have a
    // cached answer for, however many passwords share that prefix.
    let hashesByPrefix = Dictionary(grouping: hashesNeedingLookup) { String($0.prefix(5)) }
    for (prefix, hashes) in hashesByPrefix {
      let suffixes = await fetchSuffixes(forPrefix: prefix)
      for hash in hashes {
        let suffix = String(hash.dropFirst(5))
        let isCompromised = suffixes?.contains(suffix) ?? false
        resultCache[hash] = isCompromised
        if isCompromised { compromisedHashes.insert(hash) }
      }
    }

    var result = Set<ID>()
    for (hash, ids) in idsByHash where compromisedHashes.contains(hash) {
      result.formUnion(ids)
    }
    return result
  }

  /// Fetches every suffix HIBP returns for `prefix` (already uppercased 5 hex characters), or
  /// `nil` if the request failed for any reason. `Add-Padding: true` asks HIBP to pad the
  /// response with decoy suffix:count lines so its size doesn't leak how many (if any) real
  /// matches it contains — see the type's doc comment.
  private func fetchSuffixes(forPrefix prefix: String) async -> Set<String>? {
    await waitForRateLimit()

    guard let url = URL(string: prefix, relativeTo: rangeAPIBaseURL) else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("true", forHTTPHeaderField: "Add-Padding")

    do {
      let (data, response) = try await session.data(for: request)
      lastRequestFinishedAt = clock.now
      guard let http = response as? HTTPURLResponse, http.statusCode == 200,
        let body = String(data: data, encoding: .utf8)
      else {
        return nil
      }
      return Self.parseSuffixes(fromResponseBody: body)
    } catch {
      lastRequestFinishedAt = clock.now
      return nil
    }
  }

  /// Sleeps, if needed, so at least ``minimumRequestInterval`` has elapsed since the previous
  /// request finished.
  private func waitForRateLimit() async {
    guard let lastRequestFinishedAt else { return }
    let elapsed = clock.now - lastRequestFinishedAt
    let remaining = minimumRequestInterval - elapsed.timeInterval
    guard remaining > 0 else { return }
    try? await Task.sleep(for: .seconds(remaining))
  }

  /// Parses a Pwned Passwords range response body — lines of `SUFFIX:COUNT`, one per known suffix
  /// for the requested prefix, plus padding lines HIBP mixes in when `Add-Padding: true` was sent
  /// (which look identical; we don't need to tell them apart, since they're vanishingly unlikely
  /// to collide with a real suffix we're looking for, and a false "compromised" from a padding
  /// collision is indistinguishable from — and no worse than — a real one for this feature's
  /// purposes) — into the set of suffixes present.
  static func parseSuffixes(fromResponseBody body: String) -> Set<String> {
    var suffixes = Set<String>()
    // `isNewline`, not `== "\n" || == "\r"`: HIBP terminates lines with CRLF, and Swift's
    // `Character` treats "\r\n" as a single extended grapheme cluster that is equal to neither
    // "\n" nor "\r" alone, so comparing against those two literals never splits a CRLF-terminated
    // body at all — every suffix but the first silently vanished into one giant unparsed "line".
    // `Character.isNewline` recognizes CR, LF, and CRLF (as the one cluster it is) alike.
    for line in body.split(whereSeparator: { $0.isNewline }) {
      guard let colonIndex = line.firstIndex(of: ":") else { continue }
      suffixes.insert(String(line[line.startIndex..<colonIndex]))
    }
    return suffixes
  }

  /// The uppercase hex SHA-1 digest of `password`, matching the format Pwned Passwords expects
  /// (and returns suffixes in).
  static func sha1Hex(_ password: String) -> String {
    let digest = Insecure.SHA1.hash(data: Data(password.utf8))
    return digest.map { String(format: "%02X", $0) }.joined()
  }
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let (seconds, attoseconds) = self.components
    return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
  }
}
