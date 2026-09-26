import AppKit

/// 851-2441: opens System Settings straight to the pane that lets the user turn on lil passwords
/// as an AutoFill provider — "System Settings → General → AutoFill & Passwords" in the ticket's
/// own words. There's no `SMAppService`-style API for this the way
/// `HelperAgentRegistering.openSystemSettingsLoginItems()` has for Login Items (that one wraps a
/// real `SMAppService.openSystemSettingsLoginItems()` call); the only documented mechanism for
/// jumping straight to a System Settings pane is an `x-apple.systempreferences:` URL, so that's
/// what this wraps instead. Kept as its own tiny type (mirroring `HelperAgentRegistering`'s
/// "own type per system integration" shape) so `GeneralSettingsView`'s button stays a one-line
/// call regardless of how the URL is built.
enum AutoFillSystemSettings {
  /// The Passwords pane's extension identifier — confirmed working via `open
  /// x-apple.systempreferences:com.apple.Passwords-Settings.extension` on macOS Ventura and
  /// later, which is also where "AutoFill & Passwords" actually lives.
  private static let url = URL(string: "x-apple.systempreferences:com.apple.Passwords-Settings.extension")!

  static func open() {
    NSWorkspace.shared.open(url)
  }
}
