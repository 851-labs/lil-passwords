import AppKit
import LilPasswordsKit

/// Fallback implementations for menu actions that don't have a real destination yet.
///
/// `AppDelegate` is always the last stop in the responder chain before AppKit gives up on a
/// `nil`-targeted action (see `NSApplication`'s "if the application object doesn't handle the
/// action, its delegate gets a chance" behavior), so implementing a selector here — even as a
/// stub — is what keeps every menu item enabled today. A later ticket makes an action "real" by
/// implementing the *same* `@objc` selector on whatever view controller should actually handle
/// it (e.g. `ItemListViewController` for `newPassword(_:)`, 851-2416); that object sits earlier
/// in the responder chain, so it wins automatically and this fallback simply stops being called.
/// Nothing in `MainMenu.swift` needs to change when that happens.
@MainActor
extension AppDelegate {
  @objc func showSettings(_ sender: Any?) {
    SettingsWindowController.shared.show()
  }

  @objc func newPassword(_ sender: Any?) {
    presentComingSoonAlert(title: "New Password", ticket: "851-2416")
  }

  @objc func importPasswords(_ sender: Any?) {
    guard let window = mainWindow, let vaultViewModel = mainWindowController?.vaultViewModel else { return }
    ImportFlow.presentOpenPanel(dataSource: vaultViewModel, from: window) {}
  }

  @objc func exportAllPasswords(_ sender: Any?) {
    guard let window = mainWindow, let vaultViewModel = mainWindowController?.vaultViewModel else { return }
    ExportFlow.presentExport(dataSource: vaultViewModel, from: window)
  }

  /// 851-2462: temporarily lives in the File menu (see `MainMenu.makeFileMenu()`'s comment)
  /// rather than Settings → Security, since PR #23's grouped-forms Settings rewrite is still open.
  @objc func generateNewRecoveryKey(_ sender: Any?) {
    guard let window = mainWindow else { return }
    RegenerateRecoveryKeyFlow.present(agentClient: agentClient, over: window)
  }

  @objc func find(_ sender: Any?) {
    presentComingSoonAlert(title: "Find", ticket: "851-2417")
  }

  @objc func sortByName(_ sender: Any?) {
    presentComingSoonAlert(title: "Sort By Name", ticket: "851-2414")
  }

  @objc func sortByDateModified(_ sender: Any?) {
    presentComingSoonAlert(title: "Sort By Date Modified", ticket: "851-2414")
  }

  @objc func sortByDateCreated(_ sender: Any?) {
    presentComingSoonAlert(title: "Sort By Date Created", ticket: "851-2414")
  }

  /// The app's one document-style window, if it's still around. Menu actions that need to
  /// present a sheet route through this instead of `NSApp.keyWindow` so a stray inspector/panel
  /// window can't accidentally become the sheet's parent.
  private var mainWindow: NSWindow? {
    NSApp.windows.first { $0.identifier == NSUserInterfaceItemIdentifier("MainWindow") }
  }

  private func presentComingSoonAlert(title: String, ticket: String) {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "\(title) Isn't Available Yet"
    alert.informativeText = "This will work once \(ticket) is done."
    if let window = mainWindow {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
  }
}
