import AppKit
import LilPasswordsKit

/// The three-column layout: sidebar, item list, detail. Mirrors Apple Passwords' split view
/// sizing so the window feels immediately familiar.
@MainActor
final class MainSplitViewController: NSSplitViewController {
  let sidebarViewController: SidebarViewController
  let listViewController: ItemListViewController
  let detailViewController: DetailViewController

  // Minimal, interim vault access (851-2416) — there's no real, shared `VaultViewModel` on
  // `origin/main` yet (that's 851-2415); see `VaultModel/VaultViewModel.swift`.
  private let vaultViewModel: any VaultViewModel = VaultStoreViewModel()

  init(store: VaultSnapshotStore) {
    sidebarViewController = SidebarViewController(store: store)
    listViewController = ItemListViewController(store: store)
    detailViewController = DetailViewController()
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

  /// Opens the New Password sheet (toolbar "+" → New Password…, and File → New Password / ⌘N —
  /// see `MainToolbarController` and `MainMenu.swift`). Implemented here, rather than on
  /// `ItemListViewController` as `AppDelegate+MenuActions.swift`'s comment suggests as an
  /// example, because this controller is guaranteed to be `window.contentViewController` and
  /// therefore in the responder chain; that's what lets this `@objc` selector take priority over
  /// `AppDelegate`'s stub fallback without any change to `MainMenu.swift` (851-2416).
  @objc func newPassword(_ sender: Any?) {
    guard let window = view.window else { return }
    NewPasswordSheetController.present(vaultViewModel: vaultViewModel, from: window) { [weak self] outcome in
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
