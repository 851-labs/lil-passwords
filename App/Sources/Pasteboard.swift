import AppKit
import LilPasswordsKit

/// The one seam every "copy this secret" affordance in the UI should go through — passwords and
/// TOTP codes alike (851-2423).
///
/// Marks the copy `org.nspasteboard.ConcealedType`/`org.nspasteboard.TransientType` — conventions
/// several clipboard managers, and Universal Clipboard, already respect to skip history/sync for
/// sensitive copies (see https://nspasteboard.org) — and clears the pasteboard again a while
/// later, but only if it still holds this exact copy (`NSPasteboard.changeCount` unchanged), so a
/// delayed clear never wipes out something the user copied afterward instead. The actual "wait,
/// then compare, then maybe clear" logic lives in `ClipboardAutoClear` (`LilPasswordsKit`), kept
/// AppKit-free there so it has real unit test coverage; this is the thin, real-`NSPasteboard`
/// call site.
@MainActor
enum Pasteboard {
  private enum HygieneType {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
  }

  #if DEBUG
    /// Overrides `AppSettings.shared.clipboardClearInterval` for tophat recordings, so "copy, then
    /// watch it clear" doesn't need to sit around for a real 30-120 second wait. Never read
    /// outside DEBUG builds. Defaults to the `LIL_PASSWORDS_DEBUG_CLIPBOARD_CLEAR_INTERVAL`
    /// environment variable (if set to a valid `TimeInterval`) so a launch-time override doesn't
    /// require modifying any source; `nil` means "use the real setting."
    static var debugClearIntervalOverride: TimeInterval? = {
      guard let raw = ProcessInfo.processInfo.environment["LIL_PASSWORDS_DEBUG_CLIPBOARD_CLEAR_INTERVAL"],
        let value = TimeInterval(raw)
      else { return nil }
      return value
    }()
  #endif

  /// Copies `value` (a password or a TOTP code) to the general pasteboard, marks it
  /// concealed/transient, and schedules the auto-clear per `AppSettings.shared.clipboardClearInterval`
  /// (skipped entirely if that setting is `.never`).
  static func copySecret(_ value: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
    pasteboard.setString("", forType: HygieneType.concealed)
    pasteboard.setString("", forType: HygieneType.transient)

    guard let interval = clearInterval else { return }
    let changeCountAfterCopy = pasteboard.changeCount
    let autoClear = ClipboardAutoClear(clock: SystemClipboardClock())
    Task {
      await autoClear.clearAfterDelay(interval, target: pasteboard, changeCountAfterCopy: changeCountAfterCopy)
    }
  }

  private static var clearInterval: TimeInterval? {
    #if DEBUG
      if let debugClearIntervalOverride { return debugClearIntervalOverride }
    #endif
    return AppSettings.shared.clipboardClearInterval.timeInterval
  }

  /// Copies non-secret text (851-2432: the "Copy Setup" MCP config snippets/commands) to the
  /// general pasteboard as a plain string. Deliberately doesn't go through `copySecret(_:)` — that
  /// path's concealed/transient marking and scheduled auto-clear exist to protect passwords and
  /// TOTP codes, and would be actively wrong here: a copied setup command is meant to be pasted
  /// into a terminal or config file, sync normally, and stay on the clipboard until the user
  /// replaces it.
  static func copyText(_ value: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
  }
}

extension NSPasteboard: ClipboardTarget {
  public func clear() {
    clearContents()
  }
}
