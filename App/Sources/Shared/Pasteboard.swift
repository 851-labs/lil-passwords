import AppKit

/// The app-side seam for copying a secret (a password, a verification code) to the system
/// pasteboard. Every "click to copy" gesture in the app goes through this, rather than calling
/// `NSPasteboard` directly, so callers stay testable/stubbable without needing a real pasteboard.
///
/// `ItemListViewController`'s existing "Copy Password"/"Copy Verification Code" context menu
/// actions predate this seam and call `NSPasteboard` directly (851-2414) — left as-is here to keep
/// this change minimal; only new code (the Codes view, 851-2418) is written against this.
@MainActor
enum Pasteboard {
  static func copySecret(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}
