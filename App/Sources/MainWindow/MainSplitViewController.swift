import AppKit
import LilPasswordsKit

/// The three-column layout: sidebar, item list, detail. Mirrors Apple Passwords' split view
/// sizing so the window feels immediately familiar.
@MainActor
final class MainSplitViewController: NSSplitViewController {
  let sidebarViewController: SidebarViewController
  let listViewController: ItemListViewController
  let detailViewController: DetailViewController

  // The same `VaultViewModel` the list/detail panes already read from (851-2415) — 851-2416's
  // New Password sheet saves through this rather than a second, private vault access path.
  private let dataSource: VaultViewModel

  init(store: VaultSnapshotStore, dataSource: VaultViewModel) {
    self.dataSource = dataSource
    sidebarViewController = SidebarViewController(store: store)
    listViewController = ItemListViewController(dataSource: dataSource)
    detailViewController = DetailViewController(vaultViewModel: dataSource)
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    sidebarViewController.delegate = self
    listViewController.delegate = self

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

  /// Opens the New Password sheet (toolbar "+" → New Password…, and File → New Password / ⌘N —
  /// see `MainToolbarController` and `MainMenu.swift`). Implemented here, rather than on
  /// `ItemListViewController` as `AppDelegate+MenuActions.swift`'s comment suggests as an
  /// example, because this controller is guaranteed to be `window.contentViewController` and
  /// therefore in the responder chain; that's what lets this `@objc` selector take priority over
  /// `AppDelegate`'s stub fallback without any change to `MainMenu.swift` (851-2416).
  @objc func newPassword(_ sender: Any?) {
    guard let window = view.window else { return }
    NewPasswordSheetController.present(vaultViewModel: dataSource, from: window) { [weak self] outcome in
      guard case .saved(let item) = outcome else { return }
      self?.detailViewController.show(item: item)
    }
  }
}

extension MainSplitViewController: SidebarViewControllerDelegate {
  func sidebarViewController(_ controller: SidebarViewController, didSelect category: SidebarCategory) {
    listViewController.select(category: category)
    detailViewController.showNoSelection(for: category)
  }
}

extension MainSplitViewController: ItemListViewControllerDelegate {
  func itemListViewController(_ controller: ItemListViewController, didChangeSelection items: [PasswordItem]) {
    switch items.count {
    case 0:
      detailViewController.showNoSelection(for: listViewController.currentCategory)
    case 1:
      detailViewController.show(item: items[0])
    default:
      detailViewController.showMultipleSelection(count: items.count)
    }
  }
}
