import Foundation

/// How long the vault may sit unlocked with no user activity before `LilPasswordsAgent` locks it
/// automatically.
///
/// **Seam**: 851-2424 lands the real, `AppSettings`-backed conformer (the Settings → Security
/// "Lock after" picker), the same pattern `AccessPolicyProviding` already uses for the "Allow
/// agents to access passwords" toggle (851-2428). Until then, `Agent/Sources/main.swift` wires in
/// ``FixedAutoLockPolicy`` at this ticket's own hardcoded 5-minute default.
public protocol AutoLockPolicyProviding: Sendable {
  /// The idle timeout, or `nil` to disable idle-timeout auto-lock entirely. Sleep and screen-lock
  /// auto-lock are unconditional and don't consult this at all — see `AutoLockTrigger`.
  func idleTimeout() async -> TimeInterval?
}

/// A fixed idle timeout that never changes at runtime — this ticket's default until 851-2424
/// supplies a live, user-configurable value.
public struct FixedAutoLockPolicy: AutoLockPolicyProviding {
  public var timeout: TimeInterval?

  /// Defaults to 5 minutes, per this ticket's description ("on idle timeout (AppSettings value if
  /// present, default 5 minutes)").
  public init(timeout: TimeInterval? = 5 * 60) {
    self.timeout = timeout
  }

  public func idleTimeout() async -> TimeInterval? { timeout }
}
