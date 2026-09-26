import CoreFoundation
import Foundation

/// Cross-process change notification via Darwin notifications, per
/// `docs/adr/0001-storage-and-process-model.md`'s decision (d): posted by whichever process just
/// wrote to the vault database, observed by every other process (and, harmlessly, by the poster
/// itself — see `VaultStore.notifyOfLocalChange`) so each can re-read the file.
///
/// Darwin notifications carry no payload and aren't restricted by App Sandbox either way, and —
/// unlike `NSDistributedNotificationCenter` or a `CFRunLoop`-driven callback — delivery doesn't
/// depend on the observing process pumping a run loop, which matters for `lilpass`/test-runner
/// style processes that never do.
enum DarwinNotifications {
  /// The name this project's processes agree on. Individual `VaultStore` instances can override
  /// it (see `VaultStore.init`) — tests use a fresh name per instance so parallel test runs in
  /// the same process don't cross-talk on this system-wide, unscoped channel.
  static let vaultChanged = "com.851labs.lilpasswords.vaultChanged"

  static func post(_ name: String) {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(name as CFString),
      nil,
      nil,
      true
    )
  }
}

/// Observes one Darwin notification name for as long as this instance is alive, invoking
/// `handler` (synchronously, on whatever thread the system delivers the notification on) each
/// time it fires.
///
/// Wraps `CFNotificationCenterAddObserver`'s C callback, which receives the raw pointer passed
/// as `observer` back as one of its arguments rather than supporting a Swift closure directly:
/// this class *is* that opaque context, recovered via `Unmanaged` inside the free-function
/// trampoline, so `handler` (an ordinary escaping Swift closure, stored as a property) can be
/// whatever the owner needs — no `@convention(c)` restrictions leak past this file.
final class DarwinNotificationObserver {
  private let name: CFString
  private let handler: () -> Void

  init(name: String, handler: @escaping () -> Void) {
    self.name = name as CFString
    self.handler = handler

    let observer = Unmanaged.passUnretained(self).toOpaque()
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      observer,
      { _, observer, _, _, _ in
        guard let observer else { return }
        Unmanaged<DarwinNotificationObserver>.fromOpaque(observer).takeUnretainedValue().handler()
      },
      self.name,
      nil,
      .deliverImmediately
    )
  }

  deinit {
    CFNotificationCenterRemoveObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque(),
      CFNotificationName(name),
      nil
    )
  }
}
