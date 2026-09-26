import CoreGraphics

/// Layout constant shared by the Settings tabs (General/Security/Agents), so each SwiftUI view can
/// pin to the same fixed content width without repeating the literal.
enum SettingsLayout {
  /// Fixed content width every tab uses, matching System Settings' fixed-width panels — the
  /// window itself resizes per tab (via `NSHostingController.sizingOptions`), not the content
  /// within a tab. 560 (plus window chrome) lands the window in the ~500–600pt-wide range System
  /// Settings' own panels use — 420 (the previous value) read closer to a narrow third-party
  /// preferences window than to System Settings/Passwords' own Settings.
  static let contentWidth: CGFloat = 560
}
