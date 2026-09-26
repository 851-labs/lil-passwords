import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct TOTPTests {
  struct Vector: Sendable {
    let time: TimeInterval
    let sha1: String
    let sha256: String
    let sha512: String
  }

  // RFC 6238 Appendix B seeds: the ASCII digits "1234567890" repeated to the algorithm's
  // required key length (20/32/64 bytes).
  static let sha1Seed = Data("12345678901234567890".utf8)
  static let sha256Seed = Data("12345678901234567890123456789012".utf8)
  static let sha512Seed = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

  // RFC 6238 Appendix B test vectors. All use T0 = 0, a 30s step, and 8-digit codes.
  static let vectors: [Vector] = [
    Vector(time: 59, sha1: "94287082", sha256: "46119246", sha512: "90693936"),
    Vector(time: 1_111_111_109, sha1: "07081804", sha256: "68084774", sha512: "25091201"),
    Vector(time: 1_111_111_111, sha1: "14050471", sha256: "67062674", sha512: "99943326"),
    Vector(time: 1_234_567_890, sha1: "89005924", sha256: "91819424", sha512: "93441116"),
    Vector(time: 2_000_000_000, sha1: "69279037", sha256: "90698825", sha512: "38618901"),
    Vector(time: 20_000_000_000, sha1: "65353130", sha256: "77737706", sha512: "47863826"),
  ]

  @Test(arguments: vectors)
  func rfc6238SHA1(_ vector: Vector) throws {
    let totp = try TOTP(secret: Self.sha1Seed, algorithm: .sha1, digits: 8, period: 30)
    #expect(totp.code(at: Date(timeIntervalSince1970: vector.time)) == vector.sha1)
  }

  @Test(arguments: vectors)
  func rfc6238SHA256(_ vector: Vector) throws {
    let totp = try TOTP(secret: Self.sha256Seed, algorithm: .sha256, digits: 8, period: 30)
    #expect(totp.code(at: Date(timeIntervalSince1970: vector.time)) == vector.sha256)
  }

  @Test(arguments: vectors)
  func rfc6238SHA512(_ vector: Vector) throws {
    let totp = try TOTP(secret: Self.sha512Seed, algorithm: .sha512, digits: 8, period: 30)
    #expect(totp.code(at: Date(timeIntervalSince1970: vector.time)) == vector.sha512)
  }

  @Test func rejectsEmptySecret() {
    do {
      _ = try TOTP(secret: Data())
      Issue.record("Expected TOTP.Error.emptySecret")
    } catch let error as TOTP.Error {
      #expect(error == .emptySecret)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func rejectsUnsupportedDigitCount() {
    do {
      _ = try TOTP(secret: Data([1]), digits: 7)
      Issue.record("Expected TOTP.Error.invalidDigits")
    } catch let error as TOTP.Error {
      #expect(error == .invalidDigits(7))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func rejectsNonPositivePeriod() {
    do {
      _ = try TOTP(secret: Data([1]), period: 0)
      Issue.record("Expected TOTP.Error.invalidPeriod")
    } catch let error as TOTP.Error {
      #expect(error == .invalidPeriod(0))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func defaultsMatchMostAuthenticatorApps() throws {
    let totp = try TOTP(secret: Data([1, 2, 3]))
    #expect(totp.algorithm == .sha1)
    #expect(totp.digits == 6)
    #expect(totp.period == 30)
  }

  @Test func codeIsZeroPadded() throws {
    let totp = try TOTP(secret: Self.sha1Seed, digits: 6)
    #expect(totp.code(at: Date(timeIntervalSince1970: 59)).count == 6)
  }

  @Test func nextChangeAlignsToPeriodBoundary() throws {
    let totp = try TOTP(secret: Data([1, 2, 3]), period: 30)
    #expect(totp.nextChange(after: Date(timeIntervalSince1970: 59)) == Date(timeIntervalSince1970: 60))
    #expect(totp.nextChange(after: Date(timeIntervalSince1970: 60)) == Date(timeIntervalSince1970: 90))
  }

  @Test func base32SecretProducesSameCodeAsRawSecret() throws {
    let raw = try TOTP(secret: Self.sha1Seed, digits: 8)
    let decoded = try #require(Base32.decode(Base32.encode(Self.sha1Seed)))
    let fromBase32 = try TOTP(secret: decoded, digits: 8)

    let date = Date(timeIntervalSince1970: 59)
    #expect(raw.code(at: date) == fromBase32.code(at: date))
  }
}
