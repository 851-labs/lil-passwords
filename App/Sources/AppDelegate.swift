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
  // Not `private`: `AppDelegate+MenuActions.swift` (851-2410's CSV import/export actions) reads
  // this from a separate file in the same module — `internal` (the default) is as narrow as
  // access control gets for a `let` and still allow that. (851-2462's recovery-key regeneration
  // used to read it too, back when it lived in the File menu; it's since moved to Settings →
  // Security, which constructs its own `AgentClient` instead — see
  // `SecuritySettingsViewController`.)
  let agentClient = AgentClient()
  private(set) var mainWindowController: MainWindowController?
  private var menuBarExtraController: MenuBarExtraController?

  // The real `SMAppService`-backed conformer in every build — `HelperAgentRegistering` exists as
  // a seam for `HelperAgentRegistrarTests` (in `LilPasswordsKit`), not for anything this app
  // target itself substitutes at runtime.
  private let helperAgentRegistrar: any HelperAgentRegistering = SMAppServiceHelperAgent()

  func applicationDidFinishLaunching(_ notification: Notification) {
    #if DEBUG
      applyForcedAppearanceOverrideIfNeeded()
    #endif
    NSApp.mainMenu = MainMenu.make()
    let controller = MainWindowController(agentClient: agentClient, helperAgentRegistrar: helperAgentRegistrar)
    controller.showWindow(nil)
    mainWindowController = controller
    NSApp.activate(ignoringOtherApps: true)

    // 851-2425: shares `controller`'s `vaultViewModel`/`lockCoordinator` rather than owning its
    // own copies, so the popover's contents and locked/unlocked state always agree with the main
    // window's — see `MenuBarRootViewController`'s documentation.
    menuBarExtraController = MenuBarExtraController(
      vaultViewModel: controller.vaultViewModel,
      lockCoordinator: controller.lockCoordinator,
      openMainWindow: { [weak self] in
        self?.mainWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
      }
    )

    // Must happen on every launch, before anything else here relies on the helper — first-run
    // vault setup and every unlock attempt (both kicked off by `MainWindowController`'s own
    // `LockCoordinator.refresh()`, already running by this point) go straight to
    // `NSXPCConnection(machServiceName:)`, which has nothing to resolve against until launchd
    // knows about `LilPasswordsAgent` at all. See `HelperAgentRegistrar`'s documentation.
    registerHelperAgentAndHandleOutcome()

    #if DEBUG
      RecoveryKitDebugMenu.install { [weak self] in self?.mainWindowController?.window }
      applyOpenSettingsTabOverrideIfNeeded()
      if let tophatDir = ProcessInfo.processInfo.environment["LIL_PASSWORDS_TOPHAT_DIR"] {
        // `RecoveryKitDebugMenu.runTophatCapture` calls `exit(0)` once it's done, so anything meant
        // to run in the same headless capture pass has to go before it, not after.
        ImportExportDebugMenu.runTophatCapture(outputDirectory: URL(fileURLWithPath: tophatDir))
        MenuBarExtraDebugMenu.runTophatCapture(outputDirectory: URL(fileURLWithPath: tophatDir))
        NewPasswordDebugMenu.runTophatCapture(outputDirectory: URL(fileURLWithPath: tophatDir))
        RegenerateRecoveryKeyDebugMenu.runTophatCapture(outputDirectory: URL(fileURLWithPath: tophatDir))
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
      // `HelperAgentRegistrar.registerIfNeeded(using:)` already retried `register()` once for us
      // here (851-2465: an initial `.notFound` status can be a one-time "never seen this service
      // before" quirk, not a broken build — see `HelperAgentStatus.notFound`'s documentation), so
      // reaching this case means it's still `.notFound` after that attempt: a genuinely broken
      // bundle (missing/invalid plist). Logged (not surfaced to the user) since there's no user
      // action that fixes that; a developer reading Console.app is who this is for.
      Self.helperAgentRegistrationLogger.error(
        "LilPasswordsAgent's launchd plist wasn't found in the app bundle (expected at Contents/Library/LaunchAgents) even after attempting registration — this build is broken; unlock and vault setup will fail."
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

    /// `-OpenSettingsTab general|security|agents` opens the Settings window straight to that tab
    /// on launch, DEBUG-only. Exists so tophat/manual-QA screenshots of Settings (851-2460) can be
    /// captured deterministically — by launching a build with this argument (plus
    /// `-ForceAppearance`/`-SeedSampleData`/`-AutoUnlockForTophat`) and grabbing this process' own
    /// window via `CGWindowListCopyWindowInfo` filtered on `kCGWindowOwnerPID` — rather than
    /// driving a live menu click or keyboard shortcut through `System Events`, which can't reliably
    /// be scoped to one process among several concurrently-running same-named instances on a
    /// shared machine. `SettingsTabViewController.Tab`'s raw values (`general`/`security`/`agents`)
    /// are exactly the accepted strings. Never compiled into Release builds.
    private func applyOpenSettingsTabOverrideIfNeeded() {
      guard let raw = UserDefaults.standard.string(forKey: "OpenSettingsTab"),
        let tab = SettingsTabViewController.Tab(rawValue: raw)
      else { return }
      SettingsWindowController.shared.show(tab: tab)
    }
  #endif
}
