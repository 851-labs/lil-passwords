import AppKit
import Combine
import LilPasswordsKit

/// Hosts the main window: a three-column `NSSplitViewController` (sidebar, item list, detail)
/// under a unified toolbar, matching Apple Passwords, plus (851-2411/851-2422) the lock screen
/// that replaces that split view's content for as long as the vault is locked.
///
/// Owns the app's `LockCoordinator` — the single source of truth for `LockState` — and reacts to
/// every state it publishes by swapping `window.contentViewController` between
/// `lockScreenViewController` and `splitViewController`, and toggling the toolbar's visibility to
/// match (Apple Passwords hides its toolbar entirely while locked; matched here rather than
/// merely disabling it, since there's nothing in the toolbar — search, add, share — that's
/// meaningful to show over a lock screen with no vault contents behind it).
@MainActor
final class MainWindowController: NSWindowController {
  private let store = VaultSnapshotStore()
  private let dataSource: VaultViewModel
  private let splitViewController: MainSplitViewController
  private let toolbarController = MainToolbarController()
  private let lockScreenViewController = LockScreenViewController()

  private var itemsDidChangeCancellable: AnyCancellable?
  private var wifiNetworksDidChangeCancellable: AnyCancellable?
  private var searchKeyMonitor: Any?

  /// Read access to the vault for surfaces that live outside `MainSplitViewController` — the
  /// import/export flows (851-2410), which present sheets over this window rather than being part
  /// of the split view itself.
  var vaultViewModel: VaultViewModel { dataSource }

  private let agentClient: AgentClient

  /// Shared with `MenuBarExtraController` (851-2425) so the popover's locked/unlocked UI and the
  /// main window's lock screen always agree — both are just different views onto this one state
  /// machine's `stateChanges()` stream, never two independent coordinators that could drift out
  /// of sync with each other.
  let lockCoordinator: LockCoordinator
  private var lockStateObserver: LockStateObserver?
  // 851-2441: keeps `ASCredentialIdentityStore` in sync with the real, XPC-backed vault (not
  // `dataSource`/`vaultStore` above, which is still the `InMemoryVaultStore` placeholder pending
  // the item list's own move to the real agent connection — see that property's own comment) so
  // Safari/system AutoFill can offer "lil passwords" as a source. See
  // `CredentialIdentityStoreSyncCoordinator`'s own documentation for the full rationale.
  private let credentialIdentitySyncCoordinator: CredentialIdentityStoreSyncCoordinator
  // 851-2465: consulted (never registered again here — `AppDelegate` already did that once at
  // launch) only to decide whether a helper-unreachable `UnlockFailure` should show the Login
  // Items hint, i.e. whether `.status` is currently `.requiresApproval`. Shared with `AppDelegate`
  // rather than owning a second `SMAppServiceHelperAgent` — `status` is a live query, so either
  // instance reports the same thing, but sharing one avoids the reader wondering why there are two.
  private let helperAgentRegistrar: any HelperAgentRegistering

  /// Guards against starting the first-run `setUpVault()` flow twice — `applyState(.needsVaultSetup)`
  /// can run again (e.g. a second `LockStateObserver` firing before the first `setUpVault()` call
  /// has resolved) before `LockCoordinator.state` has moved on to `.unlocked`. Only used by
  /// `startDirectVaultSetupIfNeeded()` — the onboarding path below guards on
  /// `onboardingWindowController` instead.
  private var isSettingUpVault = false

  /// The first-run onboarding walkthrough (851-2439), while it's up. `nil` the rest of the time —
  /// including before the very first `.needsVaultSetup`, and again once the walkthrough finishes
  /// or is closed early. See `presentOnboardingIfNeeded()`.
  private var onboardingWindowController: OnboardingWindowController?

  #if DEBUG
    /// Guards `-InitialSidebarCategory` (see `initialSidebarCategoryOverride()`) so it only fires
    /// the first time unlocked content is shown, not on every re-lock/unlock cycle.
    private var hasAppliedInitialSidebarCategoryOverride = false

    /// Guards `-AutoUnlockForTophat` (see `requestAutoUnlockIfNeeded()`) so it only fires once.
    private var hasRequestedAutoUnlock = false

    /// Guards `-InitialSelectedItemTitle` (see `applyInitialSelectedItemOverrideIfNeeded()`) so it
    /// only fires the first time unlocked content is shown.
    private var hasAppliedInitialSelectedItemOverride = false
  #endif

  init(agentClient: AgentClient, helperAgentRegistrar: any HelperAgentRegistering) {
    self.agentClient = agentClient
    self.helperAgentRegistrar = helperAgentRegistrar
    self.lockCoordinator = LockCoordinator(
      agent: MainWindowController.makeAgent(real: agentClient),
      authenticator: MainWindowController.makeAuthenticator()
    )
    self.credentialIdentitySyncCoordinator = CredentialIdentityStoreSyncCoordinator(agentClient: agentClient)

    // `InMemoryVaultStore` is a real `VaultStoring` conformance (851-2404) — real crypto, real
    // CRUD/change-log semantics — just without a SQLite file or cross-process Darwin
    // notifications. It stands in for the XPC-backed `VaultStore` the app will talk to once the
    // item list/detail flow is wired to the real agent connection; nothing above `VaultViewModel`
    // changes when that swap happens, and it's independent of `lockCoordinator` above (which
    // already talks to the real helper for lock state) — see that ticket's own work for when the
    // two converge.
    let vaultStore = InMemoryVaultStore()
    let dataSource = VaultStoreViewModel(store: vaultStore)
    self.dataSource = dataSource
    splitViewController = MainSplitViewController(store: store, dataSource: dataSource)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = LilPasswordsKit.productName
    // Apple Passwords shows no title text in the titlebar, just the toolbar controls.
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified
    window.identifier = NSUserInterfaceItemIdentifier("MainWindow")
    window.isRestorable = true
    window.setFrameAutosaveName("MainWindow")
    window.minSize = NSSize(width: 620, height: 400)
    window.center()

    super.init(window: window)

    lockScreenViewController.delegate = self
    // Start on the lock screen: `LockState.checking` (the coordinator's initial state, before its
    // first `refresh()` completes) renders identically to `.locked` — see `applyState(_:)` — so
    // there's no separate "loading" flash before this resolves to whatever the helper actually
    // reports.
    window.contentViewController = lockScreenViewController

    toolbarController.splitView = splitViewController.splitView
    // The search field lives in the toolbar, spanning the detail column (851-2463), but
    // `ItemListViewController`/`WiFiListViewController` still own query handling/focus — hand
    // each the field, and swap which one is the delegate as the sidebar selection changes (see
    // `onSearchDelegateChange` below), starting with `.all`'s `listViewController`, the initial
    // sidebar selection.
    toolbarController.searchField.delegate = splitViewController.listViewController
    splitViewController.listViewController.searchField = toolbarController.searchField
    splitViewController.wifiListViewController.searchField = toolbarController.searchField
    // The sort button now lives in the toolbar's list-actions capsule (851-2463); targeted
    // directly at `ItemListViewController` rather than through the responder chain, matching
    // `MainSplitViewController.newPassword`'s own reasoning for preferring an explicit target.
    toolbarController.sortButton.target = splitViewController.listViewController
    toolbarController.sortButton.action = #selector(ItemListViewController.showSortMenu(_:))
    splitViewController.listViewController.listTitleView = toolbarController.listTitleView
    splitViewController.wifiListViewController.listTitleView = toolbarController.listTitleView
    splitViewController.detailViewController.editControl = toolbarController.editControl
    // Codes/Security/Deleted (851-2418/851-2419/851-2420) replace the list+detail split with a
    // full-width view, and Wi-Fi (851-2444) keeps its own reduced list+detail chrome; none of
    // this toolbar's list/detail-column chrome applies the same way across all of these, so it's
    // swapped to match (851-2463) — see `MainToolbarController.setToolbarLayoutMode(_:)`.
    splitViewController.onToolbarLayoutModeChange = { [weak toolbarController] mode in
      toolbarController?.setToolbarLayoutMode(mode)
    }
    splitViewController.onSearchDelegateChange = { [weak toolbarController] delegate in
      toolbarController?.searchField.delegate = delegate
    }
    window.toolbar = toolbarController.makeToolbar()
    window.toolbar?.isVisible = false

    // The sidebar's Wi-Fi count (851-2444) comes from `WiFiNetworkViewModel.networks`, not
    // `dataSource.items` — known Wi-Fi networks aren't `PasswordItem`s — so the snapshot is
    // rebuilt from both sources together, and re-rebuilt whenever either one changes.
    let wifiViewModel = splitViewController.wifiViewModel
    func updateSnapshot() {
      store.update(VaultSnapshot(items: dataSource.items, wifiKnownNetworkCount: wifiViewModel.networks.count))
    }

    updateSnapshot()
    itemsDidChangeCancellable = dataSource.itemsDidChange
      .receive(on: RunLoop.main)
      .sink { _ in updateSnapshot() }
    wifiNetworksDidChangeCancellable = wifiViewModel.$networks
      .receive(on: RunLoop.main)
      .sink { _ in updateSnapshot() }

    // `start()` is async (it has to unlock the vault before any CRUD works), but `init()` isn't,
    // so it's kicked off here as an unstructured `Task` — `dataSource.items` stays empty until it
    // completes, same as any other async load, and `itemsDidChange` above picks up the result.
    Task { [dataSource] in
      var seedItems: [PasswordItem] = []
      #if DEBUG
        if SampleData.isEnabled {
          seedItems = SampleData.makeItems()
        }
      #endif
      await dataSource.start(seeding: seedItems)
    }

    // ⌘F focuses the search field (851-2417). Handled as a local event monitor, rather than a
    // `MainMenu.swift` menu item's action, since that file is 851-2424's. The search field itself
    // lives in the toolbar, spanning the list column (851-2461) — see the wiring above.
    searchKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self,
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
        event.charactersIgnoringModifiers?.lowercased() == "f"
      else {
        return event
      }
      splitViewController.listViewController.focusSearchField()
      return nil
    }

    startObservingLockState()
    credentialIdentitySyncCoordinator.start()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  isolated deinit {
    if let searchKeyMonitor {
      NSEvent.removeMonitor(searchKeyMonitor)
    }
  }

  /// Real device-owner auth (`LAContext`) in every Release build, no exceptions. DEBUG builds use
  /// the same real `LAContextAuthenticator` unless `LILPASSWORDS_FAKE_AUTH=1` is set in the
  /// environment — an explicit, opt-in-only escape hatch for manual QA and tophat capture in
  /// environments that can't press an actual Touch ID sensor (851-2411's own sandboxed worktree,
  /// for instance). Never flip this default; it exists so a plain `DEBUG` build a developer runs
  /// day to day still exercises the real unlock path.
  ///
  /// Not `private`: `AppDelegate` (851-2445) reuses this exact seam for `AgentApprovalController`'s
  /// Touch ID-gated approval dialog, rather than duplicating the `#if DEBUG`/`LILPASSWORDS_FAKE_AUTH`
  /// check a second time — see `docs/adr/0007-scoped-agent-access.md`'s "Approval flow" section,
  /// which explicitly calls for reusing this seam.
  static func makeAuthenticator() -> any VaultAuthenticating {
    #if DEBUG
      if ProcessInfo.processInfo.environment["LILPASSWORDS_FAKE_AUTH"] == "1" {
        return AlwaysSucceedAuthenticator()
      }
    #endif
    return LAContextAuthenticator()
  }

  /// The real `AgentClient` in every Release build, no exceptions. DEBUG builds use the same real
  /// connection unless `LILPASSWORDS_OFFLINE_DEMO=1` is set — see `OfflineDemoAgent`'s
  /// documentation for why a locally-built debug app can't safely drive the real helper for
  /// screenshot/manual-QA purposes on a machine running several concurrent worktrees of this app.
  private static func makeAgent(real: AgentClient) -> any VaultAgentConnecting {
    #if DEBUG
      if ProcessInfo.processInfo.environment["LILPASSWORDS_OFFLINE_DEMO"] == "1" {
        return OfflineDemoAgent()
      }
    #endif
    return real
  }

  private func startObservingLockState() {
    // Cross-process signal: the helper's lock state changed for a reason this process didn't
    // itself initiate (auto-lock — idle timeout, sleep, screen lock — or another client's
    // `.lock()`/`.unlock()`). Re-`refresh()` rather than trying to decode which of those happened;
    // `AgentStatus` is cheap to fetch and is already the single source of truth.
    lockStateObserver = LockStateObserver { [weak self] in
      guard let self else { return }
      Task { await self.lockCoordinator.refresh() }
    }

    Task { [weak self] in
      guard let self else { return }
      // Subscribe before the first `refresh()` so that refresh's resulting transition (if any)
      // is guaranteed to arrive over `stream` rather than racing it — `stateChanges()` only
      // streams *subsequent* transitions, not the state at subscription time.
      let stream = await self.lockCoordinator.stateChanges()
      Task { await self.lockCoordinator.refresh() }
      for await state in stream {
        self.applyState(state)
      }
    }
  }

  private func applyState(_ state: LockState) {
    switch state {
    case .checking:
      lockScreenViewController.applyFailurePresentation(nil)
      presentLockScreen()
    case .locked:
      lockScreenViewController.applyFailurePresentation(nil)
      presentLockScreen()
      #if DEBUG
        requestAutoUnlockIfNeeded()
      #endif
    case .unlockFailed(let failure):
      lockScreenViewController.applyFailurePresentation(failurePresentation(for: failure))
      presentLockScreen()
    case .unlocked:
      presentUnlockedContent()
    case .needsVaultSetup:
      startFirstRunVaultSetupIfNeeded()
    }
  }

  /// 851-2465: turns an `UnlockFailure` (`LilPasswordsKit`, no AppKit/UI knowledge) into the
  /// `LockScreenViewController.FailurePresentation` (App target, no `LilPasswordsKit`/XPC
  /// knowledge) that actually renders it — the one place those two deliberately-decoupled halves
  /// meet. Not helper-unreachable failures (a `.remote(AgentError)`, or a cancelled `LAContext`
  /// prompt) pass their message through unchanged, with no "Try Again"/hint/Login Items affordance
  /// — those already have their own specific, actionable description.
  private func failurePresentation(for failure: UnlockFailure) -> LockScreenViewController.FailurePresentation {
    guard failure.isHelperUnreachable else {
      return LockScreenViewController.FailurePresentation(
        message: failure.message,
        showsTryAgain: false,
        hint: nil,
        showsOpenLoginItems: false
      )
    }

    let requiresApproval = helperAgentRegistrar.status == .requiresApproval
    var hint: String?
    if requiresApproval {
      hint =
        "\(LilPasswordsKit.productName) needs to be turned on in Login Items for its helper to run."
    }
    #if DEBUG
      // Only reachable in a DEBUG build with no team identifier on its own signature (unsigned,
      // or ad-hoc — see `AgentConnectionSecurity.Requirement.developmentFallback`'s
      // documentation) — a signed DEBUG build (this ticket's Apple Development smoke test) gets
      // `.enforce` instead and never shows this. Login Items guidance, when both apply, is the
      // more actionable of the two, so it takes priority.
      if hint == nil, case .developmentFallback = AgentConnectionSecurity.requirement(acceptingPeers: [.agent]) {
        hint = "Running an unsigned/ad-hoc DEBUG build? See docs/tophat.md to run against a real helper."
      }
    #endif

    return LockScreenViewController.FailurePresentation(
      message: failure.message,
      showsTryAgain: true,
      hint: hint,
      showsOpenLoginItems: requiresApproval
    )
  }

  private func presentLockScreen() {
    guard window?.contentViewController !== lockScreenViewController else { return }
    window?.contentViewController = lockScreenViewController
    window?.toolbar?.isVisible = false
  }

  private func presentUnlockedContent() {
    // 851-2441: unlocking doesn't itself rewrite the vault database, so it never posts the vault's
    // own change notification — this is the "initial post-unlock load" trigger
    // `CredentialIdentityStoreSyncCoordinator`'s own documentation describes, run unconditionally
    // (not just the first time) since a re-lock/unlock cycle is exactly when the identity store
    // could otherwise go stale relative to changes made while this process wasn't running.
    Task { [credentialIdentitySyncCoordinator] in
      await credentialIdentitySyncCoordinator.refresh()
    }

    guard window?.contentViewController !== splitViewController else { return }
    window?.contentViewController = splitViewController
    window?.toolbar?.isVisible = true
    #if DEBUG
      applyInitialSidebarCategoryOverrideIfNeeded()
      applyInitialSelectedItemOverrideIfNeeded()
    #endif
  }

  #if DEBUG
    /// `-InitialSidebarCategory <rawValue>` (e.g. `-InitialSidebarCategory codes`) jumps straight
    /// to that sidebar category as soon as the vault unlocks, DEBUG-only. Exists so tophat/manual-QA
    /// screenshots of the full-width Codes/Security/Deleted views (851-2418/851-2419/851-2420) can
    /// be captured deterministically — by launching a build with this argument (plus
    /// `-SeedSampleData YES`) and grabbing this process' own window via
    /// `CGWindowListCopyWindowInfo` filtered on `kCGWindowOwnerPID` — rather than by driving a live
    /// sidebar click through `System Events`, which can't reliably be scoped to one process among
    /// several concurrently-running same-named instances on a shared machine. `SidebarCategory`'s
    /// `rawValue`s (`all`/`passkeys`/`codes`/`wifi`/`security`/`deleted`) are exactly the accepted
    /// strings. Never compiled into Release builds.
    private func applyInitialSidebarCategoryOverrideIfNeeded() {
      guard !hasAppliedInitialSidebarCategoryOverride else { return }
      guard let raw = UserDefaults.standard.string(forKey: "InitialSidebarCategory"),
        let category = SidebarCategory(rawValue: raw)
      else { return }
      hasAppliedInitialSidebarCategoryOverride = true
      splitViewController.sidebarViewController.selectCategory(category)
    }

    /// `-InitialSelectedItemTitle <title>` (e.g. `-InitialSelectedItemTitle Amazon`) selects the
    /// matching row in the item list as soon as the vault unlocks, DEBUG-only — same rationale and
    /// same "no System Events/AX" constraint as `-InitialSidebarCategory` above, but for producing
    /// a deterministic "row selected" tophat screenshot (851-2463) instead of driving a live click.
    /// Applied after `applyInitialSidebarCategoryOverrideIfNeeded()` so the list is already showing
    /// whichever category the row is expected to be found in. Never compiled into Release builds.
    private func applyInitialSelectedItemOverrideIfNeeded() {
      guard !hasAppliedInitialSelectedItemOverride else { return }
      guard let title = UserDefaults.standard.string(forKey: "InitialSelectedItemTitle") else { return }
      hasAppliedInitialSelectedItemOverride = true
      splitViewController.listViewController.selectItem(withTitle: title)
    }

    /// `-AutoUnlockForTophat YES` drives `lockCoordinator.unlock()` as soon as `.locked` is
    /// observed, DEBUG-only — combined with `LILPASSWORDS_FAKE_AUTH=1`/`LILPASSWORDS_OFFLINE_DEMO=1`
    /// (see `makeAuthenticator()`/`makeAgent(real:)`), this gets a freshly-launched debug build
    /// straight to unlocked content with no Touch ID/password prompt and no click needed, so a
    /// tophat/manual-QA screenshot pass (see `-InitialSidebarCategory`/`-ForceAppearance`) can run
    /// end-to-end from launch arguments alone. Never compiled into Release builds.
    private func requestAutoUnlockIfNeeded() {
      guard !hasRequestedAutoUnlock else { return }
      guard UserDefaults.standard.bool(forKey: "AutoUnlockForTophat") else { return }
      hasRequestedAutoUnlock = true
      Task { await lockCoordinator.unlock() }
    }
  #endif

  /// First run (851-2411/851-2439): no vault exists yet. The very first time this happens, that
  /// means showing the full onboarding walkthrough (851-2439) rather than jumping straight to
  /// vault creation — it owns calling `setUpVault()` and handing off to the recovery kit sheet
  /// itself, from its own "Create Your Vault" step. `AppSettings.hasCompletedOnboarding` is what
  /// tells the two paths apart: once someone's actually been through the walkthrough, landing back
  /// on `.needsVaultSetup` again (e.g. the vault file went missing out from under the helper) goes
  /// straight to the old, direct path instead of showing the welcome screens a second time.
  private func startFirstRunVaultSetupIfNeeded() {
    presentLockScreen()

    if AppSettings.shared.hasCompletedOnboarding {
      startDirectVaultSetupIfNeeded()
    } else {
      presentOnboardingIfNeeded()
    }
  }

  /// The pre-851-2439 behavior: ask the helper to create a vault, then hand off to the recovery
  /// kit "save your recovery key" sheet (851-2447) directly, with none of onboarding's other
  /// steps.
  private func startDirectVaultSetupIfNeeded() {
    guard !isSettingUpVault else { return }
    isSettingUpVault = true

    Task { [weak self] in
      guard let self else { return }
      defer { self.isSettingUpVault = false }
      do {
        let recoveryKeyDisplayString = try await self.lockCoordinator.setUpVault()
        self.presentRecoveryKit(recoveryKeyDisplayString: recoveryKeyDisplayString)
      } catch {
        // `LockCoordinator.setUpVault()` already moved `state` to `.unlockFailed` with this
        // error's description; the `stateChanges()` subscription above will re-render for it.
      }
    }
  }

  /// Presents the 851-2439 onboarding window, guarded on `onboardingWindowController` rather than
  /// a separate bool — `applyState(.needsVaultSetup)` can fire again (see `isSettingUpVault`'s
  /// documentation) before the window's own "Create Your Vault" step has finished, and
  /// re-presenting a second window would just be a duplicate.
  private func presentOnboardingIfNeeded() {
    guard onboardingWindowController == nil else { return }
    onboardingWindowController = OnboardingWindowController.present(
      vaultViewModel: dataSource,
      lockCoordinator: lockCoordinator,
      agentClient: agentClient
    ) { [weak self] finished in
      guard let self else { return }
      self.onboardingWindowController = nil
      if finished {
        AppSettings.shared.hasCompletedOnboarding = true
      }
      // Vault creation (onboarding's own step 2) already moved `lockCoordinator` to `.unlocked`,
      // which the `stateChanges()` subscription started in `startObservingLockState()` already
      // swapped this window's content to `splitViewController` for — this just brings that
      // already-unlocked window to the front now that onboarding's own window is gone.
      self.window?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  /// `AgentResponse.vaultCreated` only ever hands the app the recovery key's rendered
  /// `displayString` (see that case's documentation) — never the raw `VaultCrypto.RecoveryKey`/its
  /// entropy, so it never has to cross XPC. `RecoveryKitFlow.presentAfterVaultCreation` wants the
  /// structured `RecoveryKey` (it needs the raw entropy to render the PDF/QR code), so it's
  /// reconstructed here from the same display string the helper generated it from — round-tripping
  /// through `displayString` is exactly what a user re-typing this same string on the restore path
  /// does, so this must always succeed for a well-formed helper response.
  private func presentRecoveryKit(recoveryKeyDisplayString: String) {
    guard let window else { return }
    guard let recoveryKey = VaultCrypto.RecoveryKey(displayString: recoveryKeyDisplayString) else {
      assertionFailure("helper returned a recovery key display string that doesn't round-trip")
      return
    }
    RecoveryKitFlow.presentAfterVaultCreation(recoveryKey: recoveryKey, over: window) { saved in
      // `false` just means "ask again later" (see `RecoveryKitFlow`'s documentation) — the vault
      // itself is already created and unlocked either way, so there's nothing to retry here yet;
      // a future Settings entry point can re-show this sheet on demand.
    }
  }
}

extension MainWindowController: LockScreenViewControllerDelegate {
  func lockScreenViewControllerDidRequestUnlock(_ controller: LockScreenViewController) {
    Task { await lockCoordinator.unlock() }
  }

  func lockScreenViewControllerDidRequestTryAgain(_ controller: LockScreenViewController) {
    Task { await lockCoordinator.refresh() }
  }

  func lockScreenViewControllerDidRequestOpenLoginItems(_ controller: LockScreenViewController) {
    helperAgentRegistrar.openSystemSettingsLoginItems()
  }
}
