/// HMAC hash algorithm used to compute an HOTP/TOTP code, per RFC 6238 §1.2.
public enum TOTPAlgorithm: String, Sendable, Hashable, CaseIterable, Codable {
  case sha1 = "SHA1"
  case sha256 = "SHA256"
  case sha512 = "SHA512"
}
