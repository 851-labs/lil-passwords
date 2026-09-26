import Foundation
import LocalAuthentication

/// Something that can prompt the user to prove they're the device owner (Touch ID/Face ID/the
/// account password fallback) before an especially sensitive action proceeds.
///
/// Exists so callers — currently just exporting the vault to a plaintext CSV — don't depend on
/// `LAContext` directly and can inject a fake in tests instead of driving a real biometric prompt.
public protocol DeviceAuthenticating: Sendable {
  /// Prompts for device-owner authentication, with `reason` shown as the prompt's explanation
  /// text on platforms that display one.
  ///
  /// Returns normally on success. Throws if authentication fails, is cancelled, or isn't
  /// available at all (e.g. no biometrics or password enrolled) — callers should treat any error
  /// as "don't proceed" and surface it, rather than inspecting the specific failure reason.
  func authenticate(reason: String) async throws
}

/// The real ``DeviceAuthenticating`` implementation, backed by `LocalAuthentication`.
///
/// Uses `LAPolicy.deviceOwnerAuthentication` (Touch ID/Face ID, falling back to the account
/// password) rather than `.deviceOwnerAuthenticationWithBiometrics`, so a Mac with no biometric
/// hardware enrolled still lets the user through via their password instead of hard-failing.
public struct LAContextDeviceAuthenticator: DeviceAuthenticating {
  public init() {}

  public func authenticate(reason: String) async throws {
    let context = LAContext()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
        if success {
          continuation.resume()
        } else {
          continuation.resume(throwing: error ?? LAError(.authenticationFailed))
        }
      }
    }
  }
}
