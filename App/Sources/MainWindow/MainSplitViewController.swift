import AppKit

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
      didPerformInitialSelection = true
      if let first = vaultViewModel.items.first {
        detailViewController.show(item: first)
        return
      }
    }
    detailViewController.showNoSelection(for: category)
  }
}
