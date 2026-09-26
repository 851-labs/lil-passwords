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
  private var searchKeyMonitor: Any?

  /// Read access to the vault for surfaces that live outside `MainSplitViewController` — the
  /// import/export flows (851-2410), which present sheets over this window rather than being part
  /// of the split view itself.
  var vaultViewModel: VaultViewModel { dataSource }

  private let agentClient: AgentClient
  private let lockCoordinator: LockCoordinator
  private var lockStateObserver: LockStateObserver?

  /// Guards against starting the first-run `setUpVault()` flow twice — `applyState(.needsVaultSetup)`
  /// can run again (e.g. a second `LockStateObserver` firing before the first `setUpVault()` call
  /// has resolved) before `LockCoordinator.state` has moved on to `.unlocked`.
  private var isSettingUpVault = false

  init(agentClient: AgentClient) {
    self.agentClient = agentClient
    self.lockCoordinator = LockCoordinator(
      agent: MainWindowController.makeAgent(real: agentClient),
      authenticator: MainWindowController.makeAuthenticator()
    )


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
    // The search field lives in the toolbar (851-2461), spanning the list column between two
    // tracking separators, but `ItemListViewController` still owns query handling/focus — hand it
    // the field and make it the delegate.
    toolbarController.searchField.delegate = splitViewController.listViewController
    splitViewController.listViewController.searchField = toolbarController.searchField
    window.toolbar = toolbarController.makeToolbar()
    window.toolbar?.isVisible = false

    store.update(VaultSnapshot(items: dataSource.items))
    itemsDidChangeCancellable = dataSource.itemsDidChange
      .receive(on: RunLoop.main)
      .sink { [weak self] in
        guard let self else { return }
        store.update(VaultSnapshot(items: dataSource.items))
      }

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
  private static func makeAuthenticator() -> any VaultAuthenticating {
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
    case .checking, .locked:
      lockScreenViewController.setUnlockFailureMessage(nil)
      presentLockScreen()
    case .unlockFailed(let message):
      lockScreenViewController.setUnlockFailureMessage(message)
      presentLockScreen()
    case .unlocked:
      presentUnlockedContent()
    case .needsVaultSetup:
      startFirstRunVaultSetupIfNeeded()
    }
  }

  private func presentLockScreen() {
    guard window?.contentViewController !== lockScreenViewController else { return }
    window?.contentViewController = lockScreenViewController
    window?.toolbar?.isVisible = false
  }

  private func presentUnlockedContent() {
    guard window?.contentViewController !== splitViewController else { return }
    window?.contentViewController = splitViewController
    window?.toolbar?.isVisible = true
  }

  /// First run (851-2411): no vault exists yet, so ask the helper to create one, then hand off to
  /// the real recovery kit "save your recovery key" sheet (851-2447).
  private func startFirstRunVaultSetupIfNeeded() {
    guard !isSettingUpVault else { return }
    isSettingUpVault = true
    presentLockScreen()

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
}
