import AppKit
import LilPasswordsKit

/// The three-column layout: sidebar, item list, detail. Mirrors Apple Passwords' split view
/// sizing so the window feels immediately familiar.
///
/// Codes/Security/Deleted (851-2418/851-2419/851-2420) are single full-width views in Apple
/// Passwords, not list+detail splits, so for those three categories the list column collapses and
/// `detailItem`'s hosted content is swapped (via `DetailContainerViewController`) to the matching
/// full-width controller; selecting `.all` restores the normal `PasswordItem` list+detail layout.
/// `.wifi` (851-2444) and `.passkeys` (851-2442) are a third kind of case: each keeps a visible
/// two-column list+detail split like `.all`, but backed by `WiFiNetwork`/`PasskeyMetadata`, not
/// `PasswordItem`, so both `listItem` and `detailItem`'s hosted content are swapped (via a second
/// `DetailContainerViewController`, `listContainerViewController`) to `wifiListViewController`/
/// `wifiDetailViewController` or `passkeysListViewController`/`passkeysDetailViewController`
/// instead of reusing `listViewController`/`detailViewController`.
/// Neither `listItem.viewController` nor `detailItem.viewController` is ever reassigned after
/// `addSplitViewItem` — see `DetailContainerViewController`'s doc comment for why.
@MainActor
final class MainSplitViewController: NSSplitViewController {
  let sidebarViewController: SidebarViewController
  let listViewController: ItemListViewController
  let detailViewController: DetailViewController
  let codesViewController: CodesViewController
  let securityViewController: SecurityViewController
  let deletedViewController: DeletedViewController
  let wifiViewModel: WiFiNetworkViewModel
  let wifiListViewController: WiFiListViewController
  let wifiDetailViewController: WiFiDetailViewController
  let passkeysViewModel: PasskeysViewModel
  let passkeysListViewController: PasskeysListViewController
  let passkeysDetailViewController: PasskeyDetailViewController

  /// Fires whenever the sidebar selection changes, naming which toolbar layout now applies —
  /// `MainWindowController` wires this to `MainToolbarController.setToolbarLayoutMode(_:)`.
  /// `.fullWidth` for Codes/Security/Deleted (none of the list/detail-column chrome has anything
  /// to apply to over a single full-width view); `.wifi`/`.passkeys` for those categories (their
  /// own reduced layout — list title and search, but no sort/"+" capsule); `.splitView` (the
  /// default) for `.all`.
  var onToolbarLayoutModeChange: ((ToolbarLayoutMode) -> Void)?

  /// Fires alongside `onToolbarLayoutModeChange` with whichever list controller should now
  /// receive the toolbar search field's delegate callbacks (`nil` while a full-width category
  /// view, which has no search, is showing) — `MainWindowController` wires this to
  /// `MainToolbarController.searchField.delegate`.
  var onSearchDelegateChange: ((NSSearchFieldDelegate?) -> Void)?

  private let listContainerViewController = DetailContainerViewController()
  private let detailContainerViewController = DetailContainerViewController()

  private var sidebarItem: NSSplitViewItem!
  private var listItem: NSSplitViewItem!
  private var detailItem: NSSplitViewItem!

  // The same `VaultViewModel` the list/detail panes already read from (851-2415) — 851-2416's
  // New Password sheet saves through this rather than a second, private vault access path.
  private let dataSource: VaultViewModel

  init(store: VaultSnapshotStore, dataSource: VaultViewModel, agentClient: AgentClient) {
    self.dataSource = dataSource
    sidebarViewController = SidebarViewController(store: store)
    listViewController = ItemListViewController(dataSource: dataSource)
    detailViewController = DetailViewController(vaultViewModel: dataSource)
    codesViewController = CodesViewController(dataSource: dataSource)
    securityViewController = SecurityViewController(dataSource: dataSource)
    deletedViewController = DeletedViewController(dataSource: dataSource)
    let wifiViewModel = WiFiNetworkViewModel()
    self.wifiViewModel = wifiViewModel
    wifiListViewController = WiFiListViewController(viewModel: wifiViewModel)
    wifiDetailViewController = WiFiDetailViewController(viewModel: wifiViewModel)
    let passkeysViewModel = PasskeysViewModel(agentClient: agentClient)
    self.passkeysViewModel = passkeysViewModel
    passkeysListViewController = PasskeysListViewController(viewModel: passkeysViewModel)
    passkeysDetailViewController = PasskeyDetailViewController(viewModel: passkeysViewModel)
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
    wifiListViewController.delegate = self
    passkeysListViewController.delegate = self

    splitView.autosaveName = "MainSplitView"
    splitView.identifier = NSUserInterfaceItemIdentifier("MainSplitView")

    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
    sidebarItem.minimumThickness = 180
    sidebarItem.maximumThickness = 260
    sidebarItem.canCollapse = true
    sidebarItem.titlebarSeparatorStyle = .none

    listContainerViewController.setContentViewController(listViewController)
    let listItem = NSSplitViewItem(contentListWithViewController: listContainerViewController)
    listItem.minimumThickness = 240
    listItem.maximumThickness = 420
    // Programmatically collapsed for the full-width categories (Codes/Security/Deleted); see
    // `sidebarViewController(_:didSelect:)`.
    listItem.canCollapse = true
    listItem.titlebarSeparatorStyle = .line

    detailContainerViewController.setContentViewController(detailViewController)
    let detailItem = NSSplitViewItem(viewController: detailContainerViewController)
    detailItem.minimumThickness = 360
    detailItem.canCollapse = false
    detailItem.titlebarSeparatorStyle = .line

    self.sidebarItem = sidebarItem
    self.listItem = listItem
    self.detailItem = detailItem

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

  /// The full-width controller for a category that replaces the list+detail split, or `nil` for
  /// categories that use a list+detail layout. `.wifi`/`.passkeys` are handled separately, before
  /// this is ever consulted — see `sidebarViewController(_:didSelect:)` — since each needs its own
  /// list+detail pair rather than either a full-width controller or `PasswordItem`'s list+detail
  /// controllers.
  private func fullWidthViewController(for category: SidebarCategory) -> NSViewController? {
    switch category {
    case .codes: return codesViewController
    case .security: return securityViewController
    case .deleted: return deletedViewController
    case .all, .passkeys, .wifi: return nil
    }
  }
}

extension MainSplitViewController: SidebarViewControllerDelegate {
  func sidebarViewController(_ controller: SidebarViewController, didSelect category: SidebarCategory) {
    if category == .wifi {
      // Wi-Fi keeps a real list+detail split — unlike Codes/Security/Deleted it's not a single
      // full-width view — but it's backed by `WiFiNetwork`, not `PasswordItem`, so it gets its own
      // pair of view controllers swapped into both containers rather than reusing
      // `listViewController`/`detailViewController`.
      listContainerViewController.setContentViewController(wifiListViewController)
      detailContainerViewController.setContentViewController(wifiDetailViewController)
      listItem.isCollapsed = false
      wifiDetailViewController.show(network: nil)
      // `detailViewController` isn't on screen while Wi-Fi is showing, but its toolbar Edit
      // control lives independently in the toolbar (see the full-width branch below) — disable it
      // here the same way, since editing a `PasswordItem` makes no sense over a Wi-Fi selection.
      detailViewController.showNoSelection(for: category)
      onToolbarLayoutModeChange?(.wifi)
      onSearchDelegateChange?(wifiListViewController)
    } else if category == .passkeys {
      // Same shape as the `.wifi` branch above: a real list+detail split, backed by
      // `PasskeyMetadata` rather than `PasswordItem`, so it gets its own pair of view controllers
      // swapped into both containers.
      listContainerViewController.setContentViewController(passkeysListViewController)
      detailContainerViewController.setContentViewController(passkeysDetailViewController)
      listItem.isCollapsed = false
      passkeysDetailViewController.show(passkey: nil)
      detailViewController.showNoSelection(for: category)
      onToolbarLayoutModeChange?(.passkeys)
      onSearchDelegateChange?(passkeysListViewController)
    } else if let fullWidthViewController = fullWidthViewController(for: category) {
      listContainerViewController.setContentViewController(listViewController)
      detailContainerViewController.setContentViewController(fullWidthViewController)
      listItem.isCollapsed = true
      // `detailViewController` (and the toolbar's Edit/Cancel/Done control, 851-2463) stay alive
      // even though `detailContainerViewController` no longer hosts their view — `editControl`
      // lives in the *toolbar*, which is independent of the split view's content and therefore
      // still visible/clickable while a full-width view is showing. Reset here so a draft that
      // was mid-edit when the user switched away can't be silently committed or discarded by a
      // Return/Esc keypress meant for the full-width view, and so Edit itself is disabled rather
      // than reopening an editor for content that isn't on screen.
      detailViewController.showNoSelection(for: category)
      onToolbarLayoutModeChange?(.fullWidth)
      onSearchDelegateChange?(nil)
    } else {
      listContainerViewController.setContentViewController(listViewController)
      detailContainerViewController.setContentViewController(detailViewController)
      listItem.isCollapsed = false
      listViewController.select(category: category)
      detailViewController.showNoSelection(for: category)
      onToolbarLayoutModeChange?(.splitView)
      onSearchDelegateChange?(listViewController)
    }
  }
}

extension MainSplitViewController: WiFiListViewControllerDelegate {
  func wifiListViewController(_ controller: WiFiListViewController, didSelect network: WiFiNetwork?) {
    wifiDetailViewController.show(network: network)
  }
}

extension MainSplitViewController: PasskeysListViewControllerDelegate {
  func passkeysListViewController(_ controller: PasskeysListViewController, didSelect passkey: PasskeyMetadata?) {
    passkeysDetailViewController.show(passkey: passkey)
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

  func itemListViewControllerDidRequestEdit(_ controller: ItemListViewController) {
    detailViewController.beginEditingCurrentItem()
  }
}
