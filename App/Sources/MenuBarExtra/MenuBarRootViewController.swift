import AppKit
import LilPasswordsKit

/// The popover's single root view controller (851-2425): swaps between the locked state, the
/// search/Suggested list, and an item's detail as `LockCoordinator.stateChanges()` and the user's
/// navigation dictate — mirroring how `MainWindowController` swaps its window's
/// `contentViewController` between the lock screen and the split view, just one level lower
/// (content view controller containment instead of window content).
///
/// Takes the *same* `LockCoordinator` instance `MainWindowController` owns (passed in by
/// `AppDelegate`), rather than creating its own, so the popover's locked/unlocked UI and the main
/// window's can never drift out of sync with each other — both are just independent subscribers
/// to the one shared state machine.
@MainActor
final class MenuBarRootViewController: NSViewController {
  static let popoverSize = NSSize(width: 300, height: 400)

  private let vaultViewModel: VaultViewModel
  private let lockCoordinator: LockCoordinator
  private let openMainWindow: () -> Void

  private let lockedViewController = MenuBarLockedViewController()
  private let listViewController: MenuBarListViewController
  private let detailViewController = MenuBarItemDetailViewController()

  private var stateObservationTask: Task<Void, Never>?
  private var isUnlocked = false

  init(vaultViewModel: VaultViewModel, lockCoordinator: LockCoordinator, openMainWindow: @escaping () -> Void) {
    self.vaultViewModel = vaultViewModel
    self.lockCoordinator = lockCoordinator
    self.openMainWindow = openMainWindow
    self.listViewController = MenuBarListViewController(vaultViewModel: vaultViewModel)
    super.init(nibName: nil, bundle: nil)

    lockedViewController.delegate = self
    listViewController.delegate = self
    detailViewController.delegate = self
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func loadView() {
    // An `NSPopover`'s own background is a vibrant material that tracks the *system* appearance —
    // not necessarily whatever appearance a given window is forced to (tophat capture forces
    // light/dark explicitly per screenshot) — so paint an explicit opaque background here. Every
    // child (list/detail/locked) draws over this rather than the popover's own translucent chrome,
    // and `OpaqueBackgroundView` re-fills on every appearance change rather than baking in
    // whatever `NSColor.windowBackgroundColor` resolved to at `loadView()` time.
    self.view = OpaqueBackgroundView(frame: NSRect(origin: .zero, size: Self.popoverSize))
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    startObservingLockState()
  }

  isolated deinit {
    stateObservationTask?.cancel()
  }

  /// Called by `MenuBarExtraController` right before the popover opens — resets navigation back to
  /// the search list (Apple Passwords never remembers a prior detail selection across an open/close
  /// cycle) and refreshes the "Suggested" section for whatever the frontmost browser shows right now.
  func popoverWillShow() {
    if isUnlocked {
      showList()
    }
    listViewController.popoverWillShow()
  }

  #if DEBUG
    /// Drives the search field/item-selection navigation from `MenuBarExtraDebugMenu`'s tophat
    /// capture, which has no real keyboard/mouse to type a query or click a row with.
    func debugSetSearchQuery(_ query: String) {
      listViewController.setSearchQuery(query)
    }

    /// ditto, for capturing the item-detail screen.
    func debugSelectItem(_ item: PasswordItem) {
      showDetail(for: item)
    }
  #endif

  private func startObservingLockState() {
    stateObservationTask = Task { [weak self] in
      guard let self else { return }
      // `state` first (no transition can be missed between reading it and subscribing to
      // subsequent ones), same ordering `MainWindowController.startObservingLockState()` uses.
      let currentState = await self.lockCoordinator.state
      self.applyState(currentState)
      let stream = await self.lockCoordinator.stateChanges()
      for await state in stream {
        self.applyState(state)
      }
    }
  }

  private func applyState(_ state: LockState) {
    switch state {
    case .checking, .locked, .needsVaultSetup:
      // `.needsVaultSetup` (no vault created yet) is folded into the same locked presentation:
      // `MainWindowController` owns the real first-run "create a vault" flow, so the popover just
      // shows its Unlock button, which will surface whatever error `setUpVault()`/`unlock()`
      // produces via `.unlockFailed` rather than trying to run its own copy of that flow.
      isUnlocked = false
      lockedViewController.setUnlockFailureMessage(nil)
      presentLocked()
    case .unlockFailed(let message):
      isUnlocked = false
      lockedViewController.setUnlockFailureMessage(message)
      presentLocked()
    case .unlocked:
      isUnlocked = true
      showList()
    }
  }

  private func presentLocked() {
    setContent(lockedViewController)
  }

  private func showList() {
    setContent(listViewController)
  }

  private func showDetail(for item: PasswordItem) {
    // `setContent` first: if this is the detail view's first-ever appearance, accessing its
    // `.view` here is what triggers `loadView()`, which sets each action button's *static*
    // default title (`configureActionButton(copyCodeButton, title: "Copy Code", ...)`). Calling
    // `configure(with:)` afterward, rather than before, means its TOTP countdown title (set via
    // `restartTOTPCountdownIfNeeded()`) is the last write and so is never clobbered by that
    // one-time default — both happen synchronously with no run-loop turn in between, so nothing
    // stale is ever actually drawn to screen.
    setContent(detailViewController)
    detailViewController.configure(with: item)
  }

  private func setContent(_ child: NSViewController) {
    guard children.first !== child else { return }
    for existingChild in children {
      existingChild.view.removeFromSuperview()
      existingChild.removeFromParent()
    }
    addChild(child)
    child.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(child.view)
    NSLayoutConstraint.activate([
      child.view.topAnchor.constraint(equalTo: view.topAnchor),
      child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
  }
}

extension MenuBarRootViewController: MenuBarLockedViewControllerDelegate {
  func menuBarLockedViewControllerDidRequestUnlock(_ controller: MenuBarLockedViewController) {
    Task { await lockCoordinator.unlock() }
  }
}

extension MenuBarRootViewController: MenuBarListViewControllerDelegate {
  func menuBarListViewController(_ controller: MenuBarListViewController, didSelect item: PasswordItem) {
    showDetail(for: item)
  }

  func menuBarListViewControllerDidRequestOpenApp(_ controller: MenuBarListViewController) {
    openMainWindow()
  }
}

extension MenuBarRootViewController: MenuBarItemDetailViewControllerDelegate {
  func menuBarItemDetailViewControllerDidRequestBack(_ controller: MenuBarItemDetailViewController) {
    showList()
  }

  func menuBarItemDetailViewControllerDidRequestOpenApp(_ controller: MenuBarItemDetailViewController) {
    openMainWindow()
  }
}

/// A plain opaque `windowBackgroundColor` fill that repaints on every effective-appearance change,
/// rather than a `wantsLayer`/`CGColor` background (which would bake in whatever the color
/// resolved to at the moment it was set, and never update again).
private final class OpaqueBackgroundView: NSView {
  override var isOpaque: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}
