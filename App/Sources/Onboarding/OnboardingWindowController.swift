import AppKit
import LilPasswordsKit
import SwiftUI

/// The first-run "welcome to lil passwords" walkthrough (851-2439): a standalone,
/// Setup-Assistant-style window `MainWindowController` shows instead of going straight into its
/// old, direct `LockCoordinator.setUpVault()` call the very first time the app runs (no vault
/// exists yet). Six steps — see ``Step`` — each their own SwiftUI page (``OnboardingPageView``),
/// swapped into `window.contentViewController` one at a time, the same technique
/// `RecoveryKitSheetController`/`ImportSheetController` use for their own multi-step sheets.
///
/// This is a standalone window rather than a sheet on the main window deliberately: step 2 needs
/// to present the existing recovery kit sheet (``RecoveryKitFlow``) *over* this window once the
/// vault is created, and a window can't sheet over another window that's already a sheet.
/// Everything this reuses instead of reimplementing — vault creation, the recovery kit, CSV
/// import, the agent-access toggle — is called exactly the way the rest of the app already calls
/// it; this file only adds the ordering and the welcome/explanation/done screens around them.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
  enum Step: CaseIterable {
    case welcome, createVault, unlock, importPasswords, agents, done
  }

  private let vaultViewModel: VaultViewModel
  private let lockCoordinator: LockCoordinator
  private let createVaultViewModel: OnboardingCreateVaultViewModel
  private let agentSettingsViewModel: AgentSettingsViewModel

  /// `true` once `completion` has fired (from `finish(completed:)`, however that was reached), so
  /// a `window.close()` triggered by `finish(completed:true)` itself doesn't turn around and fire
  /// `windowWillClose`'s own "closed early" completion a second time.
  private var didFinish = false

  /// Receives `true` once the user reaches the end (step 6's "Open lil passwords"), or `false` if
  /// the window is closed before that — e.g. the traffic-light close button. `MainWindowController`
  /// only marks `AppSettings.hasCompletedOnboarding` on `true`; either way, it drops its reference
  /// to this controller so a later `.needsVaultSetup` can present a fresh one.
  private var completion: ((Bool) -> Void)?

  init(vaultViewModel: VaultViewModel, lockCoordinator: LockCoordinator, agentClient: AgentClient) {
    self.vaultViewModel = vaultViewModel
    self.lockCoordinator = lockCoordinator
    self.createVaultViewModel = OnboardingCreateVaultViewModel(lockCoordinator: lockCoordinator)
    self.agentSettingsViewModel = AgentSettingsViewModel(client: agentClient)

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: OnboardingLayout.contentSize),
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = LilPasswordsKit.productName
    // Matches `MainWindowController`'s own lock screen: traffic lights only, no title text, so
    // this reads as a welcome screen rather than a document window.
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.identifier = NSUserInterfaceItemIdentifier("OnboardingWindow")
    // Every step renders at the exact same fixed size (`OnboardingLayout.contentSize`); resizing
    // would just letterbox that content, so it's left out of the style mask entirely rather than
    // fighting a resizable window back to size on every step change.
    window.center()

    super.init(window: window)
    window.delegate = self

    createVaultViewModel.onVaultCreated = { [weak self] displayString in
      self?.presentRecoveryKit(recoveryKeyDisplayString: displayString)
    }

    show(.welcome)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Presents the window and refreshes the agent-access toggle from the helper (`agentSettings()`),
  /// same as `AgentsSettingsView` does on appear.
  static func present(
    vaultViewModel: VaultViewModel,
    lockCoordinator: LockCoordinator,
    agentClient: AgentClient,
    completion: @escaping (Bool) -> Void
  ) -> OnboardingWindowController {
    let controller = OnboardingWindowController(
      vaultViewModel: vaultViewModel, lockCoordinator: lockCoordinator, agentClient: agentClient
    )
    controller.completion = completion
    Task { await controller.agentSettingsViewModel.refresh() }
    controller.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    return controller
  }

  // MARK: - Steps

  private func show(_ step: Step) {
    window?.contentViewController = makeViewController(for: step)
  }

  private func makeViewController(for step: Step) -> NSViewController {
    switch step {
    case .welcome:
      return NSHostingController(
        rootView: OnboardingWelcomeView(onContinue: { [weak self] in self?.show(.createVault) }))

    case .createVault:
      return NSHostingController(rootView: OnboardingCreateVaultView(viewModel: createVaultViewModel))

    case .unlock:
      return NSHostingController(
        rootView: OnboardingUnlockView(
          onOpenSecuritySettings: { [weak self] in self?.openSecuritySettings() },
          onContinue: { [weak self] in self?.show(.importPasswords) }
        )
      )

    case .importPasswords:
      return NSHostingController(
        rootView: OnboardingImportView(
          onImportCSV: { [weak self] in self?.presentImportPanel() },
          onSkip: { [weak self] in self?.show(.agents) }
        )
      )

    case .agents:
      return NSHostingController(
        rootView: OnboardingAgentsView(
          agentSettings: agentSettingsViewModel,
          onInstallCLI: { [weak self] in self?.presentInstallCLIComingSoon() },
          onContinue: { [weak self] in self?.show(.done) },
          onSkip: { [weak self] in self?.show(.done) }
        )
      )

    case .done:
      return NSHostingController(
        rootView: OnboardingDoneView(onOpenMainWindow: { [weak self] in self?.finish(completed: true) }))
    }
  }

  // MARK: - Step 2: create vault → recovery kit

  /// `AgentResponse.vaultCreated` (and therefore `LockCoordinator.setUpVault()`) only ever hands
  /// back the recovery key's rendered `displayString`, never the raw entropy — see
  /// `MainWindowController.presentRecoveryKit`'s documentation for why. Reconstructing it here,
  /// the same way, is what lets this hand off to the unmodified `RecoveryKitFlow`.
  private func presentRecoveryKit(recoveryKeyDisplayString: String) {
    guard let window else { return }
    guard let recoveryKey = VaultCrypto.RecoveryKey(displayString: recoveryKeyDisplayString) else {
      assertionFailure("helper returned a recovery key display string that doesn't round-trip")
      show(.unlock)
      return
    }
    RecoveryKitFlow.presentAfterVaultCreation(recoveryKey: recoveryKey, over: window) { [weak self] _ in
      // `false` just means "ask again later" (see `RecoveryKitFlow`'s documentation), not a
      // failure — the vault is already created either way, so onboarding always continues.
      self?.show(.unlock)
    }
  }

  // MARK: - Step 3: unlock explanation

  /// Jumps Settings straight to the Security tab (auto-lock timing) rather than just opening
  /// Settings on whatever tab it last showed — same `SettingsWindowController.show(tab:)` entry
  /// point `AppDelegate`'s `-OpenSettingsTab` DEBUG override uses.
  private func openSecuritySettings() {
    SettingsWindowController.shared.show(tab: .security)
  }

  // MARK: - Step 4: import

  private func presentImportPanel() {
    guard let window else { return }
    // Whatever happens next — an actual import, or the panel/sheet being cancelled — there's
    // nothing left for this step to do once it's over, so it always advances.
    ImportFlow.presentOpenPanel(dataSource: vaultViewModel, from: window) { [weak self] in
      self?.show(.agents)
    }
  }

  // MARK: - Step 5: agents

  /// The hook 851-2432 ("install the `lilpass` command") replaces. Mirrors
  /// `AppDelegate+MenuActions.presentComingSoonAlert`'s wording for every other not-yet-built menu
  /// action in this app, rather than inventing new copy for this one placeholder.
  private func presentInstallCLIComingSoon() {
    guard let window else { return }
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Installing the Command Isn't Available Yet"
    alert.informativeText =
      "This will work once 851-2432 is done. You can always add \(LilPasswordsKit.cliName) to your PATH manually for now."
    alert.beginSheetModal(for: window)
  }

  // MARK: - Finishing

  private func finish(completed: Bool) {
    guard !didFinish else { return }
    didFinish = true
    completion?(completed)
    completion = nil
    if let window, window.isVisible {
      window.close()
    }
  }

  func windowWillClose(_ notification: Notification) {
    finish(completed: false)
  }
}
