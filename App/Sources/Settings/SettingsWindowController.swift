import AppKit

/// Hosts the Settings window: a toolbar-style `NSTabViewController` with General, Security, and
/// Agents tabs, matching how System Settings and most AppKit apps present preferences (851-2424).
///
/// One shared instance, created lazily and reused, so choosing "Settings…" twice in a row raises
/// the same window instead of spawning a second one.
@MainActor
final class SettingsWindowController: NSWindowController {
  static let shared = SettingsWindowController()

  private init() {
    let tabViewController = SettingsTabViewController()
    let window = NSWindow(contentViewController: tabViewController)
    window.title = "Settings"
    window.identifier = NSUserInterfaceItemIdentifier("SettingsWindow")
    // Settings windows are System Settings-style panels: fixed per-tab size, not user-resizable,
    // and not part of window-cycling/restoration the way the main document window is.
    window.styleMask = [.titled, .closable, .miniaturizable]
    window.isRestorable = false
    window.center()
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Shows the Settings window, bringing the app to the front so it's immediately visible even
  /// if the app wasn't active when "Settings…" was chosen. Pass `tab` to also jump straight to a
  /// specific tab (see `AppDelegate`'s `-OpenSettingsTab` DEBUG override, which is the only caller
  /// that does today).
  ///
  /// Order matters here: the window is put on screen *before* switching tabs, not after.
  /// `SettingsTabViewController`'s resize-on-select logic forces a layout pass and reads the
  /// newly-selected child's `fittingSize` — ordering front first means `viewDidLoad`'s own initial
  /// resize (for General, the tab it always starts on) has already run, so a subsequent `selectTab`
  /// switches tabs the same way a live click would, rather than being the very first layout/resize
  /// this window has ever gone through.
  func show(tab: SettingsTabViewController.Tab? = nil) {
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
    if let tab, let tabViewController = window?.contentViewController as? SettingsTabViewController {
      tabViewController.selectTab(tab)
    }
  }
}
