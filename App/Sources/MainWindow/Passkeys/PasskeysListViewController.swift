import AppKit
import Combine
import LilPasswordsKit

@MainActor
protocol PasskeysListViewControllerDelegate: AnyObject {
  func passkeysListViewController(_ controller: PasskeysListViewController, didSelect passkey: PasskeyMetadata?)
}

/// The Passkeys category's list column: every passkey the vault currently holds, each row showing
/// its site and user name — matching the ticket's "Passkeys category lists passkeys (site, user)."
///
/// Modeled on ``WiFiListViewController`` (851-2444, the freshest non-`PasswordItem` list+detail
/// category at the time this was written): its own data doesn't come from `VaultViewModel` either,
/// so this owns a small dedicated view model (``PasskeysViewModel``) instead of taking a
/// `VaultViewModel` the way ``ItemListViewController`` does. Unlike Wi-Fi, rows here reuse the
/// shared ``CredentialRowView`` (`LilPasswordsKit`) — the same row `ItemListViewController` and the
/// AutoFill extension's own picker list use — via its primitive `configure(title:subtitle:
/// hidesSeparator:)`, rather than a bespoke row cell, since a passkey's "site, user" shape is
/// exactly what that primitive already renders.
///
/// There's deliberately no "+" add button in this list, matching Wi-Fi: passkeys are only ever
/// created by a relying party's own registration flow (via the AutoFill extension), never typed in
/// by hand here.
@MainActor
final class PasskeysListViewController: NSViewController {
  weak var delegate: PasskeysListViewControllerDelegate?

  private let viewModel: PasskeysViewModel
  private var cancellable: AnyCancellable?
  private var lockedCancellable: AnyCancellable?

  private var searchQuery: String = ""
  private var rows: [PasskeyMetadata] = []

  /// The toolbar's search field — same ownership/delegate-swap pattern as
  /// `WiFiListViewController.searchField`/`ItemListViewController.searchField`.
  weak var searchField: NSSearchField?

  /// The toolbar's two-line title ("Passkeys" + "N Passkeys") — same pattern as
  /// `WiFiListViewController.listTitleView`.
  weak var listTitleView: ListTitleToolbarView?

  private let scrollView = NSScrollView()
  private let tableView = PasskeysTableView()
  private let emptyStateView = EmptyStateView()

  private let contextMenu = NSMenu()
  private let deleteMenuItem = NSMenuItem(title: String(localized: "Delete"), action: nil, keyEquivalent: "")

  init(viewModel: PasskeysViewModel) {
    self.viewModel = viewModel
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func loadView() {
    let view = NSView()
    configureTableView()
    emptyStateView.isHidden = true

    view.addSubview(scrollView)
    view.addSubview(emptyStateView)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    emptyStateView.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      // Scrolls underneath the translucent toolbar, matching `ItemListViewController`/
      // `WiFiListViewController` (851-2463/851-2444).
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      emptyStateView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    self.view = view
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    cancellable = viewModel.$passkeys
      .receive(on: RunLoop.main)
      .sink { [weak self] passkeys in self?.applyPasskeys(passkeys) }
    lockedCancellable = viewModel.$isLocked
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.updateEmptyState() }

    viewModel.startObservingVaultChanges()
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    updateListTitle()
    Task { await viewModel.refresh() }
  }

  // MARK: Public API (called by MainSplitViewController / MainWindowController)

  /// Focuses and selects-all in the toolbar's search field, in response to ⌘F — mirrors
  /// `ItemListViewController.focusSearchField()`/`WiFiListViewController.focusSearchField()`.
  func focusSearchField() {
    guard let searchField else { return }
    view.window?.makeFirstResponder(searchField)
    if let editor = searchField.currentEditor() {
      editor.selectAll(nil)
    }
  }

  private func configureTableView() {
    tableView.headerView = nil
    tableView.usesAlternatingRowBackgroundColors = false
    tableView.allowsMultipleSelection = false
    tableView.allowsEmptySelection = true
    tableView.style = .plain
    tableView.intercellSpacing = NSSize(width: 0, height: 0)
    tableView.dataSource = self
    tableView.delegate = self
    tableView.onDeleteKey = { [weak self] in self?.confirmAndDeleteSelectedPasskey() }

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("PasskeyColumn"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)

    deleteMenuItem.target = self
    deleteMenuItem.action = #selector(deleteMenuAction(_:))
    contextMenu.delegate = self
    contextMenu.addItem(deleteMenuItem)
    tableView.menu = contextMenu

    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
  }

  // MARK: Row computation

  private func applyPasskeys(_ passkeys: [PasskeyMetadata]) {
    rebuildRows(from: passkeys)
  }

  private func updateSearch(query: String) {
    guard query != searchQuery else { return }
    searchQuery = query
    rebuildRows(from: viewModel.passkeys)
  }

  private func rebuildRows(from passkeys: [PasskeyMetadata]) {
    let previouslySelectedID = selectedPasskey()?.id

    rows = filteredPasskeys(from: passkeys)
    tableView.reloadData()

    if let previouslySelectedID, let row = rows.firstIndex(where: { $0.id == previouslySelectedID }) {
      tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    } else {
      delegate?.passkeysListViewController(self, didSelect: nil)
    }

    updateEmptyState()
    updateListTitle()
  }

  private func filteredPasskeys(from passkeys: [PasskeyMetadata]) -> [PasskeyMetadata] {
    guard !searchQuery.isEmpty else { return passkeys }
    return passkeys.filter {
      PasskeysViewModel.title(for: $0).localizedCaseInsensitiveContains(searchQuery)
        || $0.displayName.localizedCaseInsensitiveContains(searchQuery)
    }
  }

  private func updateEmptyState() {
    let hasPasskeys = !rows.isEmpty
    scrollView.isHidden = !hasPasskeys
    emptyStateView.isHidden = hasPasskeys
    guard !hasPasskeys else { return }

    if !searchQuery.isEmpty {
      emptyStateView.configure(
        symbolName: "magnifyingglass",
        title: String(localized: "No Results"),
        message: String(localized: "Try a different search.")
      )
    } else if viewModel.isLocked {
      emptyStateView.configure(
        symbolName: "lock.fill",
        title: String(localized: "Locked"),
        message: String(localized: "Unlock lil passwords to see your passkeys.")
      )
    } else {
      emptyStateView.configure(
        symbolName: SidebarCategory.passkeys.symbolName,
        title: SidebarCategory.passkeys.emptyListTitle,
        message: SidebarCategory.passkeys.emptyListMessage
      )
    }
  }

  /// Pushes "Passkeys" + "N Passkeys" into the shared toolbar title — guarded the same way
  /// `WiFiListViewController.updateListTitle()` is, so a stale publish landing after the sidebar
  /// switches away can't clobber whichever list/full-width title is actually on screen.
  private func updateListTitle() {
    guard isViewLoaded, view.window != nil else { return }
    let count = rows.count
    let subtitle = count == 1 ? String(localized: "1 Passkey") : String(localized: "\(count) Passkeys")
    listTitleView?.configure(title: SidebarCategory.passkeys.title, subtitle: subtitle)
  }

  private func selectedPasskey() -> PasskeyMetadata? {
    guard tableView.selectedRow >= 0, tableView.selectedRow < rows.count else { return nil }
    return rows[tableView.selectedRow]
  }

  /// Whether row `row`'s own hairline should be hidden — same rule as `ItemListViewController`/
  /// `WiFiListViewController`.
  private func hidesSeparator(atRow row: Int) -> Bool {
    let selected = tableView.selectedRowIndexes
    return selected.contains(row) || selected.contains(row + 1)
  }

  private func updateSeparatorVisibility() {
    for row in rows.indices {
      guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? CredentialRowView else {
        continue
      }
      cell.setSeparatorHidden(hidesSeparator(atRow: row))
    }
  }

  // MARK: Delete

  @objc private func deleteMenuAction(_ sender: Any?) {
    confirmAndDeleteSelectedPasskey()
  }

  /// Same destructive-confirmation shape `DeletedViewController.confirmAndDeletePermanently(_:in:)`
  /// uses: `.critical` alert, destructive action first, "This can't be undone," gated on
  /// `.alertFirstButtonReturn`. Shared with the detail card's own Delete button
  /// (``PasskeyDetailViewController``) via ``PasskeysViewModel/delete(id:)`` — both call sites ask
  /// first, then delete through the same view model method.
  func confirmAndDeleteSelectedPasskey() {
    guard let passkey = selectedPasskey(), let window = view.window else { return }
    PasskeyDeleteConfirmation.present(passkey, from: window) { [weak self] in
      try await self?.viewModel.delete(id: passkey.id)
    }
  }
}

extension PasskeysListViewController: NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int {
    rows.count
  }
}

extension PasskeysListViewController: NSTableViewDelegate {
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let passkey = rows[row]
    let cell = CredentialRowView.dequeue(from: tableView, owner: self)
    cell.configure(
      title: PasskeysViewModel.title(for: passkey), subtitle: passkey.displayName,
      hidesSeparator: hidesSeparator(atRow: row))
    return cell
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    // Matches `ItemListViewController`/`WiFiListViewController`'s row height.
    56
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    InsetTableRowView()
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    delegate?.passkeysListViewController(self, didSelect: selectedPasskey())
    updateSeparatorVisibility()
  }
}

extension PasskeysListViewController: NSMenuDelegate {
  func menuNeedsUpdate(_ menu: NSMenu) {
    let clickedRow = tableView.clickedRow
    guard clickedRow >= 0, rows.indices.contains(clickedRow) else {
      deleteMenuItem.isEnabled = false
      return
    }
    if !tableView.selectedRowIndexes.contains(clickedRow) {
      tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
    }
    deleteMenuItem.isEnabled = true
  }
}

extension PasskeysListViewController: NSSearchFieldDelegate {
  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSSearchField else { return }
    updateSearch(query: field.stringValue)
  }

  func searchFieldDidEndSearching(_ sender: NSSearchField) {
    updateSearch(query: "")
  }
}

/// A plain `NSTableView` that turns the standard Delete/Backspace key bindings into a callback —
/// same shape as `ItemListViewController`'s private `ItemTableView`.
private final class PasskeysTableView: NSTableView {
  var onDeleteKey: (() -> Void)?

  override func deleteBackward(_ sender: Any?) {
    onDeleteKey?()
  }

  override func deleteForward(_ sender: Any?) {
    onDeleteKey?()
  }
}
