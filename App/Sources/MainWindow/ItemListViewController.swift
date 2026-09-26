import AppKit
import Combine
import LilPasswordsKit

@MainActor
protocol ItemListViewControllerDelegate: AnyObject {
  /// Called whenever the table's selection changes, with every currently-selected item (empty
  /// if nothing is selected). `MainSplitViewController` forwards this to the detail column.
  func itemListViewController(_ controller: ItemListViewController, didChangeSelection items: [PasswordItem])
}

/// The content column: the list of items for the selected sidebar category — an `NSTableView`
/// with alphabetical section headers, a sort-options menu, multi-select, and a context menu
/// (851-2414), plus live search (851-2417).
///
/// `VaultStore` (851-2404) and the XPC helper (851-2427) aren't ready yet, so this is built
/// against ``VaultViewModel``, a small app-side protocol backed by an in-memory item list today
/// and by the real store later, with no other change needed here.
@MainActor
final class ItemListViewController: NSViewController {
  private enum Row {
    case section(String)
    case item(PasswordItem)
  }

  private let dataSource: VaultViewModel
  private var cancellable: AnyCancellable?

  private(set) var currentCategory: SidebarCategory = .all
  private var searchQuery: String = ""
  private var sortField: PasswordItemSortField = .title
  private var rows: [Row] = []

  weak var delegate: ItemListViewControllerDelegate?

  private let headerBar = NSView()
  private let countLabel = NSTextField(labelWithString: "")
  private let sortButton = NSButton()
  private let scrollView = NSScrollView()
  private let tableView = ItemTableView()
  private let emptyStateView = EmptyStateView()

  private let contextMenu = NSMenu()
  private let copyUsernameMenuItem = NSMenuItem(title: "Copy Username", action: nil, keyEquivalent: "")
  private let copyPasswordMenuItem = NSMenuItem(title: "Copy Password", action: nil, keyEquivalent: "")
  private let copyVerificationCodeMenuItem = NSMenuItem(
    title: "Copy Verification Code", action: nil, keyEquivalent: "")
  private let deleteMenuItem = NSMenuItem(title: "Delete", action: nil, keyEquivalent: "")

  private lazy var sortMenu: NSMenu = {
    let menu = NSMenu()
    for field in PasswordItemSortField.allCases {
      let item = NSMenuItem(title: sortMenuTitle(for: field), action: #selector(selectSortField(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = field
      menu.addItem(item)
    }
    return menu
  }()

  init(dataSource: VaultViewModel) {
    self.dataSource = dataSource
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func loadView() {
    let view = NSView()
    configureHeaderBar()
    configureTableView()
    configureEmptyStateView()

    view.addSubview(headerBar)
    view.addSubview(scrollView)
    view.addSubview(emptyStateView)

    headerBar.translatesAutoresizingMaskIntoConstraints = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    emptyStateView.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      // Anchored to the safe area (not `view.topAnchor`) because the window uses a transparent
      // unified toolbar (`titlebarAppearsTransparent = true`): this split-view item's content
      // extends *behind* the toolbar/search field, so pinning to the plain top anchor drew the
      // count label and sort button underneath the search pill instead of below it.
      headerBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      headerBar.heightAnchor.constraint(equalToConstant: 24),

      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      emptyStateView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
      emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    self.view = view
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    updateSortMenuCheckmarks()

    cancellable = dataSource.itemsDidChange
      .receive(on: RunLoop.main)
      .sink { [weak self] in
        self?.rebuildRows(preservingSelection: true)
      }

    rebuildRows(preservingSelection: false)
  }

  // MARK: Public API (called by MainSplitViewController / MainWindowController)

  /// Called by `MainSplitViewController` when the sidebar selection changes.
  func select(category: SidebarCategory) {
    guard category != currentCategory else { return }
    currentCategory = category
    rebuildRows(preservingSelection: false)
  }

  /// Called by `MainWindowController` whenever the toolbar search field's text changes.
  func updateSearch(query: String) {
    guard query != searchQuery else { return }
    searchQuery = query
    rebuildRows(preservingSelection: false)
  }

  // MARK: Configuration

  private func configureHeaderBar() {
    countLabel.translatesAutoresizingMaskIntoConstraints = false
    countLabel.font = .systemFont(ofSize: 11)
    countLabel.textColor = .secondaryLabelColor

    sortButton.translatesAutoresizingMaskIntoConstraints = false
    sortButton.bezelStyle = .texturedRounded
    sortButton.isBordered = false
    sortButton.image = NSImage(systemSymbolName: "arrow.up.arrow.down.circle", accessibilityDescription: "Sort")
    sortButton.imagePosition = .imageOnly
    sortButton.target = self
    sortButton.action = #selector(showSortMenu(_:))
    sortButton.toolTip = "Sort By"

    headerBar.addSubview(countLabel)
    headerBar.addSubview(sortButton)
    NSLayoutConstraint.activate([
      countLabel.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 10),
      countLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

      sortButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -8),
      sortButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
      sortButton.widthAnchor.constraint(equalToConstant: 22),
      sortButton.heightAnchor.constraint(equalToConstant: 22),
    ])
  }

  private func configureTableView() {
    tableView.headerView = nil
    tableView.usesAlternatingRowBackgroundColors = false
    tableView.allowsMultipleSelection = true
    tableView.allowsEmptySelection = true
    tableView.floatsGroupRows = true
    // `.plain` (rather than leaving `.automatic`, which resolves to extra inset padding around
    // rows/group rows in some window chrome configurations) plus zeroed `intercellSpacing`, since
    // row/section spacing is fully controlled by `tableView(_:heightOfRow:)` below — anything else
    // just stacks on top of that and produces the "twice the row height" look between sections.
    tableView.style = .plain
    tableView.intercellSpacing = NSSize(width: 0, height: 0)
    tableView.dataSource = self
    tableView.delegate = self
    tableView.onDeleteKey = { [weak self] in self?.deleteSelectedItems() }

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ItemColumn"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)

    copyUsernameMenuItem.target = self
    copyUsernameMenuItem.action = #selector(copyUsername(_:))
    copyPasswordMenuItem.target = self
    copyPasswordMenuItem.action = #selector(copyPassword(_:))
    copyVerificationCodeMenuItem.target = self
    copyVerificationCodeMenuItem.action = #selector(copyVerificationCode(_:))
    deleteMenuItem.target = self
    deleteMenuItem.action = #selector(deleteMenuAction(_:))

    contextMenu.delegate = self
    contextMenu.addItem(copyUsernameMenuItem)
    contextMenu.addItem(copyPasswordMenuItem)
    contextMenu.addItem(copyVerificationCodeMenuItem)
    contextMenu.addItem(.separator())
    contextMenu.addItem(deleteMenuItem)
    tableView.menu = contextMenu

    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
  }

  private func configureEmptyStateView() {
    emptyStateView.isHidden = true
  }

  private func sortMenuTitle(for field: PasswordItemSortField) -> String {
    switch field {
    case .title: return "Title"
    case .createdAt: return "Date Created"
    case .modifiedAt: return "Date Edited"
    case .website: return "Website"
    }
  }

  // MARK: Row computation

  private func rebuildRows(preservingSelection: Bool) {
    let previouslySelectedIDs = preservingSelection ? Set(selectedItems().map(\.id)) : []

    rows = computeRows()
    tableView.deselectAll(nil)
    tableView.reloadData()

    if !previouslySelectedIDs.isEmpty {
      let indices = rows.indices.filter { index in
        if case .item(let item) = rows[index] { return previouslySelectedIDs.contains(item.id) }
        return false
      }
      if !indices.isEmpty {
        tableView.selectRowIndexes(IndexSet(indices), byExtendingSelection: false)
      }
    }

    updateEmptyState()
    updateCountLabel()
  }

  private func computeRows() -> [Row] {
    let filtered = dataSource.items.filter { currentCategory.matches($0) }

    guard searchQuery.isEmpty else {
      return rankedRows(from: filtered)
    }

    let sorted = filtered.sorted(by: PasswordItem.sortComparator(for: sortField))
    guard sortField == .title else {
      return sorted.map { Row.item($0) }
    }
    return sectionedRows(from: sorted)
  }

  private func sectionedRows(from items: [PasswordItem]) -> [Row] {
    var rows: [Row] = []
    var lastKey: String?
    for item in items {
      let key = item.titleSectionKey
      if key != lastKey {
        rows.append(.section(key))
        lastKey = key
      }
      rows.append(.item(item))
    }
    return rows
  }

  private func rankedRows(from items: [PasswordItem]) -> [Row] {
    items.compactMap { item -> (PasswordItem, Double)? in
      guard let score = item.searchScore(for: searchQuery) else { return nil }
      return (item, score)
    }
    .sorted { lhs, rhs in
      lhs.1 == rhs.1 ? lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending : lhs.1 > rhs.1
    }
    .map { Row.item($0.0) }
  }

  private func updateEmptyState() {
    let hasItems = rows.contains { if case .item = $0 { return true } else { return false } }
    headerBar.isHidden = !hasItems
    scrollView.isHidden = !hasItems
    emptyStateView.isHidden = hasItems
    guard !hasItems else { return }

    if !searchQuery.isEmpty {
      emptyStateView.configure(
        symbolName: "magnifyingglass",
        title: "No Results",
        message: "Try a different search."
      )
    } else {
      emptyStateView.configure(
        symbolName: currentCategory.symbolName,
        title: currentCategory.emptyListTitle,
        message: currentCategory.emptyListMessage
      )
    }
  }

  private func updateCountLabel() {
    let count = rows.reduce(into: 0) { partial, row in
      if case .item = row { partial += 1 }
    }
    countLabel.stringValue = count == 1 ? "1 Item" : "\(count) Items"
  }

  private func selectedItems() -> [PasswordItem] {
    tableView.selectedRowIndexes.compactMap { index in
      guard rows.indices.contains(index), case .item(let item) = rows[index] else { return nil }
      return item
    }
  }

  private func updateSortMenuCheckmarks() {
    for item in sortMenu.items {
      item.state = (item.representedObject as? PasswordItemSortField) == sortField ? .on : .off
    }
  }

  // MARK: Actions

  @objc private func showSortMenu(_ sender: NSButton) {
    sortMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
  }

  @objc private func selectSortField(_ sender: NSMenuItem) {
    guard let field = sender.representedObject as? PasswordItemSortField, field != sortField else { return }
    sortField = field
    updateSortMenuCheckmarks()
    rebuildRows(preservingSelection: true)
  }

  @objc private func copyUsername(_ sender: Any?) {
    guard let item = selectedItems().first, selectedItems().count == 1,
      let username = item.usernames.first(where: { !$0.isEmpty })
    else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(username, forType: .string)
  }

  @objc private func copyPassword(_ sender: Any?) {
    let items = selectedItems()
    guard items.count == 1, !items[0].password.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(items[0].password, forType: .string)
  }

  @objc private func copyVerificationCode(_ sender: Any?) {
    let items = selectedItems()
    guard items.count == 1, let totp = items[0].totp else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(totp.code(), forType: .string)
  }

  @objc private func deleteMenuAction(_ sender: Any?) {
    deleteSelectedItems()
  }

  private func deleteSelectedItems() {
    let items = selectedItems()
    guard !items.isEmpty else { return }
    for item in items {
      // Moves the item to Recently Deleted (sets `deletedAt`); a no-op if it's already there.
      // There's no user-facing permanent delete yet — see `VaultViewModel.delete(_:)`.
      dataSource.delete(item)
    }
  }
}

extension ItemListViewController: NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int {
    rows.count
  }
}

extension ItemListViewController: NSTableViewDelegate {
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    switch rows[row] {
    case .section(let title):
      let cell = SectionHeaderCellView.dequeue(from: tableView, owner: self)
      cell.configure(title: title)
      return cell
    case .item(let item):
      let cell = ItemRowCellView.dequeue(from: tableView, owner: self)
      cell.configure(with: item)
      return cell
    }
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    switch rows[row] {
    case .section: return 28
    case .item: return 40
    }
  }

  func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
    if case .section = rows[row] { return true }
    return false
  }

  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    if case .section = rows[row] { return false }
    return true
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    delegate?.itemListViewController(self, didChangeSelection: selectedItems())
  }
}

extension ItemListViewController: NSMenuDelegate {
  func menuNeedsUpdate(_ menu: NSMenu) {
    let clickedRow = tableView.clickedRow
    guard clickedRow >= 0, rows.indices.contains(clickedRow), case .item = rows[clickedRow] else {
      setContextMenuEnabled(false, false, false, false)
      return
    }

    if !tableView.selectedRowIndexes.contains(clickedRow) {
      tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
    }

    let items = selectedItems()
    let single = items.count == 1 ? items[0] : nil
    setContextMenuEnabled(
      single?.usernames.first(where: { !$0.isEmpty }) != nil,
      single.map { !$0.password.isEmpty } ?? false,
      single?.totp != nil,
      !items.isEmpty
    )
  }

  private func setContextMenuEnabled(_ username: Bool, _ password: Bool, _ verificationCode: Bool, _ delete: Bool) {
    copyUsernameMenuItem.isEnabled = username
    copyPasswordMenuItem.isEnabled = password
    copyVerificationCodeMenuItem.isEnabled = verificationCode
    deleteMenuItem.isEnabled = delete
  }
}

/// Filtering rules for which items appear under each sidebar category (851-2414): `all` is every
/// non-deleted item, `codes` is non-deleted items with a TOTP secret, and `deleted` is anything
/// with `deletedAt` set. `passkeys`, `wifi`, and `security` aren't modeled by `PasswordItem` yet,
/// so they always render empty for now.
fileprivate extension SidebarCategory {
  func matches(_ item: PasswordItem) -> Bool {
    switch self {
    case .all: return item.deletedAt == nil
    case .codes: return item.deletedAt == nil && item.totpURI != nil
    case .deleted: return item.deletedAt != nil
    case .passkeys, .wifi, .security: return false
    }
  }
}

/// A plain `NSTableView` that turns the standard Delete/Backspace key bindings into a callback,
/// so the item list can support keyboard delete without needing a custom `NSResponder` subclass
/// elsewhere in the app.
private final class ItemTableView: NSTableView {
  var onDeleteKey: (() -> Void)?

  override func deleteBackward(_ sender: Any?) {
    onDeleteKey?()
  }

  override func deleteForward(_ sender: Any?) {
    onDeleteKey?()
  }
}
