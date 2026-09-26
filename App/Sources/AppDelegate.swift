import AppKit
import LilPasswordsKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private static let helperAgentRegistrationLogger = Logger(
    subsystem: "com.851labs.lilpasswords",
    category: "HelperAgentRegistration"
  )

  // Owned here, rather than by `MainWindowController`, so the "on quit" auto-lock trigger below
  // (851-2411) can send `.lock()` over the same connection the window controller has been using —
  // there's no correctness requirement that it be the same `AgentClient` (a second connection to
  // the same Mach service works fine), but reusing one avoids the helper seeing a bursty extra
  // connect/disconnect on every quit.
  private let agentClient = AgentClient()
  // `private(set)`, not plain `private`: `AppDelegate+MenuActions.swift` (851-2410's CSV
  // import/export actions) reads this from a separate file in the same module.
  private(set) var mainWindowController: MainWindowController?

  // The real `SMAppService`-backed conformer in every build — `HelperAgentRegistering` exists as
  // a seam for `HelperAgentRegistrarTests` (in `LilPasswordsKit`), not for anything this app
  // target itself substitutes at runtime.
  private let helperAgentRegistrar: any HelperAgentRegistering = SMAppServiceHelperAgent()

  func applicationDidFinishLaunching(_ notification: Notification) {
    #if DEBUG
      applyForcedAppearanceOverrideIfNeeded()
    #endif
    NSApp.mainMenu = MainMenu.make()
    let controller = MainWindowController(agentClient: agentClient)
    controller.showWindow(nil)
    mainWindowController = controller
    NSApp.activate(ignoringOtherApps: true)

    // Must happen on every launch, before anything else here relies on the helper — first-run
    // vault setup and every unlock attempt (both kicked off by `MainWindowController`'s own
    // `LockCoordinator.refresh()`, already running by this point) go straight to
    // `NSXPCConnection(machServiceName:)`, which has nothing to resolve against until launchd
    // knows about `LilPasswordsAgent` at all. See `HelperAgentRegistrar`'s documentation.
    registerHelperAgentAndHandleOutcome()

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

  /// 851-2411: registers `LilPasswordsAgent` with launchd if it isn't already, and handles each
  /// possible outcome — see `HelperAgentRegistrationOutcome`'s cases for what each one means.
  private func registerHelperAgentAndHandleOutcome() {
    let outcome = HelperAgentRegistrar.registerIfNeeded(using: helperAgentRegistrar)
    switch outcome {
    case .alreadyEnabled, .registered:
      break

    case .requiresApproval:
      presentHelperAgentApprovalSheet()

    case .notFound:
      // Shouldn't happen in a correctly-built app — see `HelperAgentStatus.notFound`'s
      // documentation. Logged (not surfaced to the user) since there's no user action that
      // fixes a broken bundle; a developer reading Console.app is who this is for.
      Self.helperAgentRegistrationLogger.error(
        "LilPasswordsAgent's launchd plist wasn't found in the app bundle (expected at Contents/Library/LaunchAgents) — this build is broken; unlock and vault setup will fail."
      )

    case .registrationFailed(let message):
      Self.helperAgentRegistrationLogger.error(
        "Failed to register LilPasswordsAgent with launchd: \(message, privacy: .public)"
      )
    }
  }

  /// Shown when `SMAppService.register()` succeeds but launchd is still waiting on the user to
  /// approve it in System Settings → General → Login Items & Extensions — until they do,
  /// launchd won't actually run `LilPasswordsAgent`, so every `AgentClient` call (unlock
  /// included) would otherwise fail with no explanation visible anywhere in this app's own UI.
  private func presentHelperAgentApprovalSheet() {
    guard let window = mainWindowController?.window else { return }
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Allow \(LilPasswordsKit.productName) to Run in the Background"
    alert.informativeText =
      "\(LilPasswordsKit.productName) needs its helper turned on in Login Items to lock and unlock your vault. Open System Settings and enable it, then reopen \(LilPasswordsKit.productName)."
    alert.addButton(withTitle: "Open System Settings")
    alert.addButton(withTitle: "Not Now")
    alert.beginSheetModal(for: window) { [helperAgentRegistrar] response in
      guard response == .alertFirstButtonReturn else { return }
      helperAgentRegistrar.openSystemSettingsLoginItems()
    }
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

  #if DEBUG
    /// `-ForceAppearance light|dark` overrides `NSApp.appearance` before any window/menu is built,
    /// DEBUG-only. Exists (alongside `MainWindowController`'s `-InitialSidebarCategory` and
    /// `SampleData`'s `-SeedSampleData`) so tophat/manual-QA screenshots can capture both
    /// appearances deterministically from self-contained launch arguments, without touching the
    /// shared, machine-wide System Settings appearance toggle — which would also affect every other
    /// app on this shared machine, including any other worktree's concurrently-running build. Never
    /// compiled into Release builds.
    private func applyForcedAppearanceOverrideIfNeeded() {
      guard let raw = UserDefaults.standard.string(forKey: "ForceAppearance") else { return }
      switch raw {
      case "light": NSApp.appearance = NSAppearance(named: .aqua)
      case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
      default: break
      }
    }
  #endif
}
