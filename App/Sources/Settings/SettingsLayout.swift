import CoreGraphics

/// Layout constant shared by the Settings tabs (General/Security/Agents), so each SwiftUI view can
/// pin to the same fixed content width without repeating the literal.
enum SettingsLayout {
  /// Fixed content width every tab uses, matching System Settings' fixed-width panels — the
  /// window itself resizes per tab (via `NSHostingController.sizingOptions`), not the content
  /// within a tab.
  static let contentWidth: CGFloat = 420
}
