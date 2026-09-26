import Foundation

/// How long the user has been idle (no keyboard/mouse/etc. input), as of "now". The real
/// conformer (`Agent/Sources/main.swift`) wraps `CGEventSourceSecondsSinceLastEventType`; tests
/// inject a fake so idle-timeout behavior is deterministic without waiting on the wall clock.
public protocol IdleTimeProviding: Sendable {
  func idleInterval() -> TimeInterval
}

/// One external signal that should lock the vault immediately, regardless of the idle timeout —
/// the display sleeping, the screen locking (the `com.apple.screenIsLocked` distributed
/// notification), or the app quitting. Every case here always locks; there is nothing to
/// "evaluate" about them the way there is for an idle timeout, which is why `AutoLockEngine` has
/// no method taking this type — `Agent/Sources/main.swift` calls `VaultStoring.lock()` directly
/// for all three, and this enum exists purely to name and document them in one place.
public enum AutoLockTrigger: Sendable, Equatable {
  case systemSleep
  case screenLocked
  case appQuit
}

/// The auto-lock decision logic `LilPasswordsAgent` drives on a timer: given the configured idle
/// timeout policy and the current idle interval, decides whether the vault should lock now.
///
/// Deliberately has no notion of "the vault" itself, or of `NSWorkspace`/
/// `DistributedNotificationCenter` — those live in `Agent/Sources/main.swift`, which owns
/// translating real system events into either a call here (for the idle timeout, which needs
/// evaluating against a policy) or a direct `VaultStoring.lock()` call (for the other triggers,
/// which always lock unconditionally). Keeping this actor free of AppKit/Foundation-notification
/// dependencies is what makes the idle-timeout decision unit-testable with an injected
/// `IdleTimeProviding` stand-in instead of a real, wall-clock-driven timer.
public actor AutoLockEngine {
  private let policy: any AutoLockPolicyProviding
  private let idleProvider: any IdleTimeProviding

  public init(policy: any AutoLockPolicyProviding, idleProvider: any IdleTimeProviding) {
    self.policy = policy
    self.idleProvider = idleProvider
  }

  /// Whether the configured idle timeout has elapsed. `false` if idle-timeout auto-lock is
  /// disabled (`AutoLockPolicyProviding.idleTimeout()` returns `nil`).
  public func shouldLockForIdleTimeout() async -> Bool {
    guard let timeout = await policy.idleTimeout() else { return false }
    return idleProvider.idleInterval() >= timeout
  }
}
