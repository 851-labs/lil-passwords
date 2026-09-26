import AppKit

/// The one seam every "copy this secret" affordance in the UI should go through.
///
/// Deliberately simple today: a plain-text copy to the general pasteboard, no expiration. Real
/// clipboard hygiene — a concealed pasteboard type so a copied password doesn't turn up in
/// Universal Clipboard or Clipboard History, plus auto-clearing the pasteboard a short while
/// after the copy — is 851-2423. That work should extend `copySecret(_:)` in place rather than
/// have call sites reach around it.
enum Pasteboard {
  /// Copies `value` (a password or verification code) to the general pasteboard.
  static func copySecret(_ value: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
  }
}
