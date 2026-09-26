import Foundation

/// Something `ClipboardAutoClear` can read a "has anything changed" counter from, and clear.
///
/// `NSPasteboard` (via the app's `Pasteboard.swift`) is the real conformer: `changeCount` is
/// exactly `NSPasteboard.changeCount`, and `clear()` is `NSPasteboard.clearContents()` with its
/// return value discarded (named differently to avoid colliding with that method's own
/// `@discardableResult func clearContents() -> Int`). Modeled as a protocol — rather than this
/// file depending on AppKit directly — so `ClipboardAutoClear` and its tests don't need AppKit at
/// all.
@MainActor
public protocol ClipboardTarget: AnyObject {
  /// A counter that increments every time anything is written to the pasteboard, by any
  /// process — including this app's own later, unrelated copies. `ClipboardAutoClear` uses this
  /// to detect "did the pasteboard change since I copied?" without needing to know or care what
  /// changed it.
  var changeCount: Int { get }

  /// Empties the pasteboard.
  func clear()
}

/// Something that can wait. Exists so `ClipboardAutoClear` is unit-testable with a fake that
/// resolves under the test's control, instead of a real ~90-second wait.
@MainActor
public protocol ClipboardClock {
  func sleep(for seconds: TimeInterval) async
}

/// The real clock, backed by `Task.sleep`.
public struct SystemClipboardClock: ClipboardClock {
  public init() {}

  public func sleep(for seconds: TimeInterval) async {
    guard seconds > 0 else { return }
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
  }
}

/// Clears a copied secret off the pasteboard some time after it was copied — but only if the
/// pasteboard still holds that exact copy, so a delayed clear never wipes out something the user
/// copied afterward instead. This is the whole of 851-2423's clipboard-hygiene *timeout*; marking
/// the copy `org.nspasteboard.ConcealedType`/`TransientType` is the app's `Pasteboard.swift`,
/// which also supplies the real `ClipboardTarget` (`NSPasteboard.general`) and `ClipboardClock`
/// this needs. Kept here, dependency-injected and AppKit-free, so the "wait, then compare
/// changeCount, then maybe clear" logic has real unit test coverage instead of only being
/// exercised by hand.
@MainActor
public struct ClipboardAutoClear<Clock: ClipboardClock> {
  public let clock: Clock

  public init(clock: Clock) {
    self.clock = clock
  }

  /// Waits `interval` seconds, then clears `target` if and only if its `changeCount` is still
  /// `changeCountAfterCopy` — i.e. nothing has been copied (by this app or anything else) since.
  /// Returns immediately, without waiting at all, if `target.changeCount` doesn't already match
  /// `changeCountAfterCopy` when called.
  public func clearAfterDelay(
    _ interval: TimeInterval,
    target: some ClipboardTarget,
    changeCountAfterCopy: Int
  ) async {
    guard target.changeCount == changeCountAfterCopy else { return }
    await clock.sleep(for: interval)
    guard target.changeCount == changeCountAfterCopy else { return }
    target.clear()
  }
}
