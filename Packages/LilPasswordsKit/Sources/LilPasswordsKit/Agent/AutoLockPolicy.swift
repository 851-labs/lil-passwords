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

/// The real, live conformer: reads Settings → Security → "Lock after" (``AppSettings/autoLockInterval``)
/// on every check, rather than snapshotting it once — the Settings window (851-2424) writes to the
/// same shared `UserDefaults` suite from a different process, so this always sees a change the
/// moment it's saved, with no notification wiring of its own needed. `AppSettings` itself already
/// registers a default (``AppSettings/AutoLockInterval/fiveMinutes``), matching this ticket's own
/// 5-minute default, so there's no separate fallback to maintain here.
public struct AppSettingsAutoLockPolicy: AutoLockPolicyProviding {
  private let settings: AppSettings

  public init(settings: AppSettings = .shared) {
    self.settings = settings
  }

  public func idleTimeout() async -> TimeInterval? {
    settings.autoLockInterval.timeInterval
  }
}
