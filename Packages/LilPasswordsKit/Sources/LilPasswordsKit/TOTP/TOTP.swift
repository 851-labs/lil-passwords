import CryptoKit
import Foundation

/// A time-based one-time password generator, as specified by RFC 6238.
///
/// `TOTP` extends HOTP (RFC 4226) by deriving the moving factor from the current time instead of
/// a counter: Unix time is divided into fixed-size steps (`period`), and the step index is
/// HMAC'd with the shared `secret` the same way an HOTP counter would be. `T0`, the RFC's
/// optional start time, is fixed at the Unix epoch, matching every authenticator app in
/// practice.
public struct TOTP: Sendable, Hashable {
  /// Errors thrown while constructing a `TOTP`.
  public enum Error: Swift.Error, Equatable, Sendable {
    /// The secret was empty.
    case emptySecret
    /// `digits` was not 6 or 8.
    case invalidDigits(Int)
    /// `period` was not a positive number of seconds.
    case invalidPeriod(TimeInterval)
  }

  /// Shared secret, as raw bytes. See ``Base32`` to decode a base32-encoded secret first.
  public var secret: Data

  /// HMAC algorithm used to compute the code. Defaults to SHA-1, matching most authenticator
  /// apps and the `otpauth://` default.
  public var algorithm: TOTPAlgorithm

  /// Number of decimal digits in the generated code. RFC 6238 vectors use 6 or 8.
  public var digits: Int

  /// Length of a time step, in seconds. Defaults to 30, per RFC 6238's recommendation.
  public var period: TimeInterval

  /// Creates a TOTP generator.
  ///
  /// - Parameters:
  ///   - secret: Shared secret bytes. Must not be empty.
  ///   - algorithm: HMAC algorithm. Defaults to `.sha1`.
  ///   - digits: Number of digits in the generated code, 6 or 8. Defaults to 6.
  ///   - period: Time step, in seconds. Must be positive. Defaults to 30.
  public init(secret: Data, algorithm: TOTPAlgorithm = .sha1, digits: Int = 6, period: TimeInterval = 30) throws {
    guard !secret.isEmpty else { throw Error.emptySecret }
    guard digits == 6 || digits == 8 else { throw Error.invalidDigits(digits) }
    guard period > 0 else { throw Error.invalidPeriod(period) }

    self.secret = secret
    self.algorithm = algorithm
    self.digits = digits
    self.period = period
  }

  /// The time-step counter for `date`: the number of whole `period`s elapsed since the Unix
  /// epoch.
  public func counter(at date: Date) -> UInt64 {
    UInt64(date.timeIntervalSince1970 / period)
  }

  /// Generates the code for the time step containing `date`.
  public func code(at date: Date = Date()) -> String {
    Self.hotp(secret: secret, counter: counter(at: date), algorithm: algorithm, digits: digits)
  }

  /// The moment the code for `date` expires and the next one begins.
  public func nextChange(after date: Date = Date()) -> Date {
    let step = counter(at: date)
    return Date(timeIntervalSince1970: Double(step + 1) * period)
  }

  /// Computes an HOTP code (RFC 4226 §5.3) for a raw counter value.
  private static func hotp(secret: Data, counter: UInt64, algorithm: TOTPAlgorithm, digits: Int) -> String {
    var counterValue = counter.bigEndian
    let counterData = withUnsafeBytes(of: &counterValue) { Data($0) }
    let hash = [UInt8](hmac(key: secret, message: counterData, algorithm: algorithm))

    let offset = Int(hash[hash.count - 1] & 0x0f)
    let truncated =
      (UInt32(hash[offset] & 0x7f) << 24) | (UInt32(hash[offset + 1]) << 16) | (UInt32(hash[offset + 2]) << 8)
      | UInt32(hash[offset + 3])

    let modulus = UInt32(pow(10, Double(digits)))
    return String(format: "%0\(digits)d", truncated % modulus)
  }

  private static func hmac(key: Data, message: Data, algorithm: TOTPAlgorithm) -> Data {
    let symmetricKey = SymmetricKey(data: key)
    switch algorithm {
    case .sha1:
      return Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symmetricKey))
    case .sha256:
      return Data(HMAC<SHA256>.authenticationCode(for: message, using: symmetricKey))
    case .sha512:
      return Data(HMAC<SHA512>.authenticationCode(for: message, using: symmetricKey))
    }
  }
}
