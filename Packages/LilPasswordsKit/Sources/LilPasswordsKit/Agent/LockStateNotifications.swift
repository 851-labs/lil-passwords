import CoreFoundation
import Foundation

/// Cross-process notification that the helper's lock state (`AgentStatus.locked`) may have
/// changed — posted by `LilPasswordsAgent` after any request that changes lock state
/// (`.createVault`, `.unlock`, `.lock`) and after an auto-lock trigger fires, and observed by the
/// app so its UI (the 851-2422 lock screen vs. the real window content) can react without
/// polling `AgentClient.status()` on a timer.
///
/// Deliberately public and separate from the vault-store `DarwinNotifications`/
/// `DarwinNotificationObserver` (both module-internal): those exist for `VaultStore` instances to
/// signal "the vault database file changed" — a storage-layer concern distinct from "the
/// process-wide lock state changed" — and keeping the two separate means this ticket's work
/// never has to touch `VaultStore`'s internals.
public enum LockStateNotifications {
  public static let lockStateChanged = "com.851labs.lilpasswords.lockStateChanged"

  public static func post() {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(lockStateChanged as CFString),
      nil,
      nil,
      true
    )
  }
}

/// Observes ``LockStateNotifications/lockStateChanged`` for as long as this instance is alive.
/// The public counterpart to the module-internal `DarwinNotificationObserver`, so `App` and
/// `Agent` targets can use it directly instead of duplicating the `CFNotificationCenter` C
/// callback trampoline.
public final class LockStateObserver {
  private let handler: () -> Void

  public init(handler: @escaping () -> Void) {
    self.handler = handler

    let observer = Unmanaged.passUnretained(self).toOpaque()
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      observer,
      { _, observer, _, _, _ in
        guard let observer else { return }
        Unmanaged<LockStateObserver>.fromOpaque(observer).takeUnretainedValue().handler()
      },
      LockStateNotifications.lockStateChanged as CFString,
      nil,
      .deliverImmediately
    )
  }

  deinit {
    CFNotificationCenterRemoveObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque(),
      CFNotificationName(LockStateNotifications.lockStateChanged as CFString),
      nil
    )
  }
}
