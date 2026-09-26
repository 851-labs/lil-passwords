import Foundation
import Security

/// Cryptographically secure random byte generation, backed by the Security framework's
/// `SecRandomCopyBytes` — the canonical CSPRNG on Apple platforms, used here for vault keys,
/// recovery key entropy, and HKDF salts.
enum SecureRandom {
  static func bytes(_ count: Int) -> Data {
    var buffer = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &buffer)
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed with status \(status)")
    return Data(buffer)
  }
}
