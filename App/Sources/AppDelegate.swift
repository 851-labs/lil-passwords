import AppKit
import LilPasswordsKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  // Owned here, rather than by `MainWindowController`, so the "on quit" auto-lock trigger below
  // (851-2411) can send `.lock()` over the same connection the window controller has been using —
  // there's no correctness requirement that it be the same `AgentClient` (a second connection to
  // the same Mach service works fine), but reusing one avoids the helper seeing a bursty extra
  // connect/disconnect on every quit.
  private let agentClient = AgentClient()
  // `private(set)`, not plain `private`: `AppDelegate+MenuActions.swift` (851-2410's CSV
  // import/export actions) reads this from a separate file in the same module.
  private(set) var mainWindowController: MainWindowController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = MainMenu.make()
    let controller = MainWindowController(agentClient: agentClient)
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

  /// Auto-lock trigger 4 of 4 (851-2411): the other three — idle timeout, sleep, screen lock —
  /// are observed by `LilPasswordsAgent` itself (see `Agent/Sources/main.swift`) since they're
  /// system-wide signals independent of any one client; quitting is specific to *this* app
  /// process, so it's handled here instead.
  ///
  /// `applicationWillTerminate` is synchronous and macOS gives it no meaningful grace period once
  /// it returns, so this blocks briefly (bounded by `lockOnQuitTimeout`) rather than firing an
  /// unstructured `Task` the process might not survive long enough to run.
  func applicationWillTerminate(_ notification: Notification) {
    let lockOnQuitTimeout: TimeInterval = 2
    let semaphore = DispatchSemaphore(value: 0)
    let agentClient = self.agentClient
    Task {
      try? await agentClient.lock()
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + lockOnQuitTimeout)
  }
}
