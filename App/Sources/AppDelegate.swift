import AppKit
import LilPasswordsKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var mainWindowController: MainWindowController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = MainMenu.make()
    let controller = MainWindowController()
    controller.showWindow(nil)
    mainWindowController = controller
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
  }
}
