import AppKit
import LilPasswordsKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var mainWindowController: MainWindowController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = MainMenu.make()
    let controller = MainWindowController(vaultViewModel: Self.makeDefaultVaultViewModel())
    controller.showWindow(nil)
    mainWindowController = controller
    NSApp.activate(ignoringOtherApps: true)

    #if DEBUG
      RecoveryKitDebugMenu.install { [weak self] in self?.mainWindowController?.window }
      if let tophatDir = ProcessInfo.processInfo.environment["LIL_PASSWORDS_TOPHAT_DIR"] {
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

  private static func makeDefaultVaultViewModel() -> VaultViewModel {
    #if DEBUG
      return VaultStoreViewModel.makeForCurrentLaunch()
    #else
      return VaultStoreViewModel()
    #endif
  }
}
