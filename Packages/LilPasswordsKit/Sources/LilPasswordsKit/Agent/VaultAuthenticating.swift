import Foundation
import LocalAuthentication

/// Evaluates device-owner authentication (Touch ID, Apple Watch, or the account password) before
/// the app asks `LilPasswordsAgent` to unlock — see docs/adr/0001-storage-and-process-model.md
/// for why this evaluation happens in the app, not the helper.
///
/// A protocol (rather than `LockCoordinator` calling `LAContext` directly) so the unlock flow is
/// testable without real biometric hardware, and so a DEBUG-only build can substitute a fake
/// conformer for tophat/manual QA in an environment (this sandboxed worktree, CI) that can't
/// press a Touch ID sensor.
public protocol VaultAuthenticating: Sendable {
  /// Evaluates device-owner authentication. Returns normally on success; throws on failure or
  /// user cancellation. Callers should treat any thrown error as "not authenticated" and show
  /// their own message rather than parse the underlying `LAError` themselves.
  func authenticateDeviceOwner(reason: String) async throws
}

/// The real conformer: `LAContext.evaluatePolicy(.deviceOwnerAuthentication, ...)`, which accepts
/// Touch ID, Apple Watch, or the account password — exactly this ticket's requirement.
public struct LAContextAuthenticator: VaultAuthenticating {
  public init() {}

  public func authenticateDeviceOwner(reason: String) async throws {
    let context = LAContext()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
        if success {
          continuation.resume()
        } else {
          continuation.resume(throwing: error ?? VaultAuthenticationError.failed)
        }
      }
    }
  }
}

/// A fallback for `LAContextAuthenticator`'s `error == nil` case, which the API allows but never
/// documents a cause for.
public enum VaultAuthenticationError: Error, Sendable, Equatable {
  case failed
}

/// Always succeeds immediately, with no system prompt at all. **DEBUG-only** by convention (never
/// wired into a Release build's `AppDelegate`) — for tests, SwiftUI-less manual QA in this
/// sandboxed worktree, and tophat recordings where nothing can press an actual Touch ID sensor.
/// See the PR description for exactly which flows were verified this way instead of with real
/// biometrics.
public struct AlwaysSucceedAuthenticator: VaultAuthenticating {
  public init() {}
  public func authenticateDeviceOwner(reason: String) async throws {}
}

/// Always fails, for tests that need to exercise the unlock-failure path deterministically.
public struct AlwaysFailAuthenticator: VaultAuthenticating {
  public struct Failure: Error, Sendable, Equatable {}
  public init() {}
  public func authenticateDeviceOwner(reason: String) async throws {
    throw Failure()
  }
}
