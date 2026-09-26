import Foundation

/// A parsed or serializable `otpauth://` URI — the de facto format (Google Authenticator's "Key
/// Uri Format") used by authenticator apps and TOTP QR codes.
///
/// Only the `totp` type is supported; `otpauth://hotp/...` URIs throw
/// ``Error/unsupportedType(_:)``, since counter-based HOTP is out of scope for this app.
public struct OTPAuthURI: Sendable, Hashable {
  /// Errors thrown while parsing an `otpauth://` URI.
  public enum Error: Swift.Error, Equatable, Sendable {
    /// The URL's scheme was not `otpauth`.
    case invalidScheme(String)
    /// The URL's host (the OTP type) was not `totp`.
    case unsupportedType(String)
    /// The URL had no path, so no label could be read.
    case missingLabel
    /// The `secret` query parameter was missing.
    case missingSecret
    /// The `secret` query parameter was not valid base32.
    case invalidSecret
    /// The `algorithm` query parameter was not `SHA1`, `SHA256`, or `SHA512`.
    case invalidAlgorithm(String)
    /// The `digits` query parameter was not `6` or `8`.
    case invalidDigits(String)
    /// The `period` query parameter was not a positive number of seconds.
    case invalidPeriod(String)
  }

  /// Display name of the issuing service, e.g. "GitHub". `nil` if the URI has none.
  public var issuer: String?

  /// Account identifier, e.g. a username or email address.
  public var accountName: String

  /// The TOTP parameters: secret, algorithm, digits, and period.
  public var totp: TOTP

  /// Creates an `otpauth://` URI representation from its parts.
  public init(issuer: String? = nil, accountName: String, totp: TOTP) {
    self.issuer = issuer
    self.accountName = accountName
    self.totp = totp
  }

  /// Parses an `otpauth://totp/...` URI, such as one decoded from a QR code.
  public init(url: URL) throws {
    guard url.scheme?.lowercased() == "otpauth" else {
      throw Error.invalidScheme(url.scheme ?? "")
    }
    guard url.host?.lowercased() == "totp" else {
      throw Error.unsupportedType(url.host ?? "")
    }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw Error.missingLabel
    }

    let label = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !label.isEmpty else { throw Error.missingLabel }

    let issuerFromLabel: String?
    let accountName: String
    if let colonIndex = label.firstIndex(of: ":") {
      issuerFromLabel = String(label[label.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
      accountName = String(label[label.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
    } else {
      issuerFromLabel = nil
      accountName = label
    }

    var parameters: [String: String] = [:]
    for item in components.queryItems ?? [] {
      parameters[item.name] = item.value
    }

    guard let secretString = parameters["secret"] else { throw Error.missingSecret }
    guard let secret = Base32.decode(secretString) else { throw Error.invalidSecret }

    let algorithm: TOTPAlgorithm
    if let raw = parameters["algorithm"] {
      guard let parsed = TOTPAlgorithm(rawValue: raw.uppercased()) else { throw Error.invalidAlgorithm(raw) }
      algorithm = parsed
    } else {
      algorithm = .sha1
    }

    let digits: Int
    if let raw = parameters["digits"] {
      guard let parsed = Int(raw), parsed == 6 || parsed == 8 else { throw Error.invalidDigits(raw) }
      digits = parsed
    } else {
      digits = 6
    }

    let period: TimeInterval
    if let raw = parameters["period"] {
      guard let parsed = TimeInterval(raw), parsed > 0 else { throw Error.invalidPeriod(raw) }
      period = parsed
    } else {
      period = 30
    }

    self.issuer = parameters["issuer"] ?? issuerFromLabel
    self.accountName = accountName
    self.totp = try TOTP(secret: secret, algorithm: algorithm, digits: digits, period: period)
  }

  /// Serializes back to an `otpauth://totp/...` URI, suitable for rendering as a QR code.
  public var url: URL {
    var components = URLComponents()
    components.scheme = "otpauth"
    components.host = "totp"
    components.path = "/" + (issuer.map { "\($0):\(accountName)" } ?? accountName)

    var queryItems = [URLQueryItem(name: "secret", value: Base32.encode(totp.secret))]
    if let issuer {
      queryItems.append(URLQueryItem(name: "issuer", value: issuer))
    }
    queryItems.append(URLQueryItem(name: "algorithm", value: totp.algorithm.rawValue))
    queryItems.append(URLQueryItem(name: "digits", value: String(totp.digits)))
    queryItems.append(URLQueryItem(name: "period", value: String(Int(totp.period))))
    components.queryItems = queryItems

    guard let url = components.url else {
      preconditionFailure("OTPAuthURI produced an invalid URL from its own components")
    }
    return url
  }
}
