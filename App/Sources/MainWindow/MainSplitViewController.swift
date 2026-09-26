import AppKit
import Combine
import LilPasswordsKit

/// The three-column layout: sidebar, item list, detail. Mirrors Apple Passwords' split view
/// sizing so the window feels immediately familiar.
@MainActor
final class MainSplitViewController: NSSplitViewController {
  let sidebarViewController: SidebarViewController
  let listViewController: ItemListViewController
  let detailViewController: DetailViewController

  private let vaultViewModel: VaultViewModel
  private var didPerformInitialSelection = false
  private var lastHandledCategory: SidebarCategory?
  private var pendingInitialCategory: SidebarCategory?
  private var itemsCancellable: AnyCancellable?

  // `vaultViewModel.itemsPublisher` is backed by a `CurrentValueSubject`, so subscribing replays
  // whatever's cached *right now* — which, for `VaultStoreViewModel`, is `[]` until its async
  // bootstrap (open the store, seed sample data, load everything back out) finishes. That replay
  // is emission #1; only from emission #2 onward can an empty array be trusted to mean "the vault
  // really is empty" rather than "hasn't loaded yet." This counter is what lets
  // `performInitialSelectionIfPossible` tell those two apart instead of flashing the empty state
  // on every launch before quietly swapping in the first item a moment later.
  private var itemsEmissionCount = 0

  init(store: VaultSnapshotStore, vaultViewModel: VaultViewModel) {
    self.vaultViewModel = vaultViewModel
    sidebarViewController = SidebarViewController(store: store)
    listViewController = ItemListViewController(store: store)
    detailViewController = DetailViewController(vaultViewModel: vaultViewModel)
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    sidebarViewController.delegate = self

    splitView.autosaveName = "MainSplitView"
    splitView.identifier = NSUserInterfaceItemIdentifier("MainSplitView")

    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
    sidebarItem.minimumThickness = 180
    sidebarItem.maximumThickness = 260
    sidebarItem.canCollapse = true
    sidebarItem.titlebarSeparatorStyle = .none

    let listItem = NSSplitViewItem(contentListWithViewController: listViewController)
    listItem.minimumThickness = 240
    listItem.maximumThickness = 420
    listItem.canCollapse = false
    listItem.titlebarSeparatorStyle = .line

    let detailItem = NSSplitViewItem(viewController: detailViewController)
    detailItem.minimumThickness = 360
    detailItem.canCollapse = false
    detailItem.titlebarSeparatorStyle = .line

    addSplitViewItem(sidebarItem)
    addSplitViewItem(listItem)
    addSplitViewItem(detailItem)

    itemsCancellable = vaultViewModel.itemsPublisher.sink { [weak self] items in
      self?.handleItemsChanged(items)
    }
  }

  private func handleItemsChanged(_ items: [PasswordItem]) {
    itemsEmissionCount += 1
    performInitialSelectionIfPossible(items: items)
  }

  /// Applies the one-time "always show something selected" default as soon as both halves of it
  /// are ready: the sidebar has told us which category to fall back to, and the vault's items have
  /// genuinely loaded (see `itemsEmissionCount`). Safe to call from either signal arriving first,
  /// in either order.
  private func performInitialSelectionIfPossible(items: [PasswordItem]) {
    guard !didPerformInitialSelection, itemsEmissionCount >= 2, let category = pendingInitialCategory else {
      return
    }
    didPerformInitialSelection = true
    if let first = items.first {
      detailViewController.show(item: first)
    } else {
      detailViewController.showNoSelection(for: category)
    }
  }
}

extension MainSplitViewController: SidebarViewControllerDelegate {
  func sidebarViewController(_ controller: SidebarViewController, didSelect category: SidebarCategory) {
    listViewController.select(category: category)

    // The sidebar re-selects its current row (and calls back here again) every time
    // `VaultSnapshotStore` publishes a new snapshot, not just once at launch — so this fires
    // repeatedly with the same category. Only react when the category actually changes, or the
    // repeat firings would clobber the detail pane right back to the empty state after the
    // one-time "select the first item" default below runs.
    guard category != lastHandledCategory else { return }
    lastHandledCategory = category

    // The sidebar's initial callback (selecting "All" as soon as its own view loads) is the
    // moment to apply Apple Passwords' "always show something selected" default, rather than the
    // empty state; a later, genuine category change still clears the detail pane, since real item
    // selection isn't wired up yet (851-2414).
    if !didPerformInitialSelection {
      pendingInitialCategory = category
      performInitialSelectionIfPossible(items: vaultViewModel.items)
      return
    }
    detailViewController.showNoSelection(for: category)
  }
}
