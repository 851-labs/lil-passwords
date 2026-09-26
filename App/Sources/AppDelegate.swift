import AppKit
import LilPasswordsKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private(set) var mainWindowController: MainWindowController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = MainMenu.make()
    let controller = MainWindowController()
    controller.showWindow(nil)
    mainWindowController = controller
    NSApp.activate(ignoringOtherApps: true)

    #if DEBUG
      RecoveryKitDebugMenu.install { [weak self] in self?.mainWindowController?.window }
      if let tophatDir = ProcessInfo.processInfo.environment["LIL_PASSWORDS_TOPHAT_DIR"] {
        // `RecoveryKitDebugMenu.runTophatCapture` calls `exit(0)` once it's done, so anything meant
        // to run in the same headless capture pass has to go before it, not after.
        ImportExportDebugMenu.runTophatCapture(outputDirectory: URL(fileURLWithPath: tophatDir))
        RecoveryKitDebugMenu.runTophatCapture(outputDirectory: URL(fileURLWithPath: tophatDir))
      }
    #endif
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
  }
}
