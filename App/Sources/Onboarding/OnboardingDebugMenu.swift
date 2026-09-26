#if DEBUG
  import AppKit
  import LilPasswordsKit
  import SwiftUI

  /// Headless tophat capture for the first-run onboarding walkthrough (851-2439), driven by the
  /// same `LIL_PASSWORDS_TOPHAT_DIR` environment variable as `ImportExportDebugMenu`/
  /// `RecoveryKitDebugMenu`/`MenuBarExtraDebugMenu` (see `AppDelegate`). Builds each of the six
  /// steps' SwiftUI views directly against fixture data/no-op closures — never by driving a real
  /// `OnboardingWindowController` through taps — and shells out to
  /// `/usr/sbin/screencapture -l<windowNumber>` for each shot, in both light and dark, using
  /// `orderFrontRegardless()` only, never `NSApp.activate` or UI-automation keystrokes, so it can't
  /// steal focus or switch Spaces on a desktop other agents may be sharing.
  ///
  /// Step 2 ("Create your vault") drives its own `LockCoordinator` against `OfflineDemoAgent` +
  /// `AlwaysSucceedAuthenticator` — the same pair `MainWindowController` uses under
  /// `LILPASSWORDS_OFFLINE_DEMO=1`/`LILPASSWORDS_FAKE_AUTH=1` — rather than the real helper
  /// connection, so this capture pass can't race another concurrently-running worktree's manual
  /// testing over the one shared Mach service/vault database — see `OfflineDemoAgent`'s
  /// documentation. Its button is never actually pressed here (that would call the real
  /// `RecoveryKitFlow`, which isn't part of this ticket's own screenshot set — `RecoveryKitDebugMenu`
  /// already covers it), so the fixture only ever needs to render the step's idle state.
  @MainActor
  enum OnboardingDebugMenu {
    static func runTophatCapture(outputDirectory: URL) {
      try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

      let lockCoordinator = LockCoordinator(agent: OfflineDemoAgent(), authenticator: AlwaysSucceedAuthenticator())
      let createVaultViewModel = OnboardingCreateVaultViewModel(lockCoordinator: lockCoordinator)
      let agentSettingsViewModel = AgentSettingsViewModel(client: AgentClient())
      let cliInstallViewModel = CLIInstallViewModel()
      cliInstallViewModel.refresh()

      let steps: [(name: String, view: AnyView)] = [
        ("welcome", AnyView(OnboardingWelcomeView(onContinue: {}))),
        ("create-vault", AnyView(OnboardingCreateVaultView(viewModel: createVaultViewModel))),
        ("unlock", AnyView(OnboardingUnlockView(onOpenSecuritySettings: {}, onContinue: {}))),
        ("import", AnyView(OnboardingImportView(onImportCSV: {}, onSkip: {}))),
        (
          "agents",
          AnyView(
            OnboardingAgentsView(
              agentSettings: agentSettingsViewModel, cliInstall: cliInstallViewModel, onContinue: {}, onSkip: {}
            )
          )
        ),
        ("done", AnyView(OnboardingDoneView(onOpenMainWindow: {}))),
      ]

      for step in steps {
        captureAsWindow(step.view, filename: "onboarding-\(step.name)-light.png", in: outputDirectory, darkMode: false)
        captureAsWindow(step.view, filename: "onboarding-\(step.name)-dark.png", in: outputDirectory, darkMode: true)
      }
    }

    private static func captureAsWindow(_ rootView: AnyView, filename: String, in directory: URL, darkMode: Bool) {
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: OnboardingLayout.contentSize),
        styleMask: [.titled, .closable, .fullSizeContentView],
        backing: .buffered,
        defer: false
      )
      window.title = LilPasswordsKit.productName
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.center()
      window.contentViewController = NSHostingController(rootView: rootView)
      // Matches `MenuBarExtraDebugMenu`'s dark-mode capture: the window's `appearance` alone only
      // changes what *new* views inherit, so the hosted SwiftUI content's own view needs the same
      // override to actually redraw dark.
      let appearance = darkMode ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
      window.appearance = appearance
      window.contentViewController?.view.appearance = appearance

      window.orderFrontRegardless()
      RunLoop.current.run(until: Date().addingTimeInterval(0.3))

      let outputURL = directory.appendingPathComponent(filename)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-o", "-l\(window.windowNumber)", outputURL.path]
      try? process.run()
      process.waitUntilExit()

      window.orderOut(nil)
    }
  }
#endif
