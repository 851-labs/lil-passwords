import AppKit
import Combine
import LilPasswordsKit

@MainActor
protocol ItemListViewControllerDelegate: AnyObject {
  /// Called whenever the table's selection changes, with every currently-selected item (empty
  /// if nothing is selected). `MainSplitViewController` forwards this to the detail column.
  func itemListViewController(_ controller: ItemListViewController, didChangeSelection items: [PasswordItem])
}

/// The content column: a single, continuous list of items for the selected sidebar category — an
/// `NSTableView` with a sort-options menu, multi-select, and a context menu (851-2414), plus live
/// search (851-2417).
///
/// Matching Apple Passwords (851-2463), this list has no alphabetical section headers — the
/// category name and item count live in the toolbar (`ListTitleToolbarView`, pushed to it below)
/// instead of an in-content header row, and the list itself scrolls underneath the translucent
/// toolbar.
///
/// `VaultStore` (851-2404) and the XPC helper (851-2427) aren't ready yet, so this is built
/// against ``VaultViewModel``, a small app-side protocol backed by an in-memory item list today
/// and by the real store later, with no other change needed here.
@MainActor
final class ItemListViewController: NSViewController {
  private let dataSource: VaultViewModel
  private let settings: AppSettings
  private var cancellable: AnyCancellable?

  private(set) var currentCategory: SidebarCategory = .all
  private var searchQuery: String = ""

  /// Backed by `AppSettings` rather than a plain stored property, so the chosen field/direction
  /// survive relaunch (851-2463's sort-menu spec).
  private var sortField: PasswordItemSortField {
    get { settings.itemListSortField }
    set { settings.itemListSortField = newValue }
  }
  private var sortDirection: SortDirection {
    get { settings.itemListSortDirection }
    set { settings.itemListSortDirection = newValue }
  }

  private var rows: [PasswordItem] = []

  weak var delegate: ItemListViewControllerDelegate?

  /// The toolbar's search field: owned and laid out by `MainToolbarController`, not here — it sits
  /// in the toolbar row itself, over the detail column (851-2463). `MainWindowController` hands it
  /// over after constructing both controllers, along with setting its delegate to `self`, so
  /// ⌘F/query handling can stay here without this view controller owning any toolbar UI.
  weak var searchField: NSSearchField?

  /// The toolbar's two-line title (category name + "N Items"), pushed to whenever `rebuildRows`
  /// runs. Owned and laid out by `MainToolbarController`; this is a weak reference handed over by
  /// `MainWindowController`, same pattern as `searchField` above.
  weak var listTitleView: ListTitleToolbarView? {
    didSet { updateListTitle() }
  }

  private let scrollView = NSScrollView()
  private let tableView = ItemTableView()
  private let emptyStateView = EmptyStateView()

  private let contextMenu = NSMenu()
  private let copyUsernameMenuItem = NSMenuItem(title: "Copy Username", action: nil, keyEquivalent: "")
  private let copyPasswordMenuItem = NSMenuItem(title: "Copy Password", action: nil, keyEquivalent: "")
  private let copyVerificationCodeMenuItem = NSMenuItem(
    title: "Copy Verification Code", action: nil, keyEquivalent: "")
  private let deleteMenuItem = NSMenuItem(title: "Delete", action: nil, keyEquivalent: "")

  /// Two sections (851-2463, matching Apple Passwords' own sort menu): which field to sort by,
  /// then a separator, then which direction — each with its own checkmark, kept in sync by
  /// `updateSortMenuCheckmarks()`.
  private lazy var sortMenu: NSMenu = {
    let menu = NSMenu()
    for field in PasswordItemSortField.allCases {
      let item = NSMenuItem(title: sortMenuTitle(for: field), action: #selector(selectSortField(_:)), keyEquivalent: "")
      item.target = self
      item.image = NSImage(systemSymbolName: sortMenuIconName(for: field), accessibilityDescription: nil)
      item.representedObject = field
      menu.addItem(item)
    }
    menu.addItem(.separator())
    for direction in SortDirection.allCases {
      let item = NSMenuItem(
        title: sortMenuTitle(for: direction), action: #selector(selectSortDirection(_:)), keyEquivalent: "")
      item.target = self
      item.image = NSImage(systemSymbolName: sortMenuIconName(for: direction), accessibilityDescription: nil)
      item.representedObject = direction
      menu.addItem(item)
    }
    return menu
  }()

  init(dataSource: VaultViewModel, settings: AppSettings = .shared) {
    self.dataSource = dataSource
    self.settings = settings
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func loadView() {
    let view = NSView()
    configureTableView()
    configureEmptyStateView()

    view.addSubview(scrollView)
    view.addSubview(emptyStateView)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    emptyStateView.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      // Pinned to the raw view edges, not the safe area guide: matching Apple Passwords
      // (851-2463), the list scrolls *underneath* the translucent unified toolbar rather than
      // stopping below it. `NSScrollView.automaticallyAdjustsContentInsets` (on by default) reads
      // `view.safeAreaInsets` to keep the table's actual content — and its resting scroll
      // position — clear of the toolbar, without this view controller doing that math itself.
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      // The empty state has no scrollable content of its own, so it stays below the toolbar
      // rather than scrolling under it.
      emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      emptyStateView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
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

  /// Focuses and selects-all in the toolbar's search field, in response to ⌘F (851-2417),
  /// forwarded here by `MainWindowController`'s local event monitor. The field itself lives in the
  /// toolbar, owned by `MainToolbarController`; `searchField` above is just a weak reference to it.
  func focusSearchField() {
    guard let searchField else { return }
    view.window?.makeFirstResponder(searchField)
    if let editor = searchField.currentEditor() {
      editor.selectAll(nil)
    }
  }

  /// Updates the current search query and rebuilds rows; called from the embedded search field's
  /// delegate methods below.
  private func updateSearch(query: String) {
    guard query != searchQuery else { return }
    searchQuery = query
    rebuildRows(preservingSelection: false)
  }

  /// The sort menu button now lives in the toolbar (`CapsuleToolbarView`, `MainToolbarController`);
  /// `MainWindowController` targets it directly at this selector, matching the direct target/action
  /// wiring the rest of the toolbar's cross-controller controls use (see `MainSplitViewController.newPassword`'s
  /// doc comment for why the codebase prefers this over responder-chain nil-targeting here).
  @objc func showSortMenu(_ sender: NSButton) {
    // `NSMenu.popUp` runs its own modal tracking loop and doesn't return until the menu is
    // dismissed, so bracketing the call is enough to keep the button visibly pressed for exactly
    // as long as the menu is open (851-2463's sort-menu spec) — no delegate/notification needed.
    sender.layer?.backgroundColor = NSColor.toolbarCapsuleButtonHighlight.cgColor
    sortMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    sender.layer?.backgroundColor = nil
  }

  // MARK: Configuration

  private func configureTableView() {
    tableView.headerView = nil
    tableView.usesAlternatingRowBackgroundColors = false
    tableView.allowsMultipleSelection = true
    tableView.allowsEmptySelection = true
    // `NSTableView.Style.inset` (tried first, per design review) turned out not to draw a rounded,
    // inset selection highlight on its own here — with a single plain column (no outline/source
    // list), its selection still fills edge-to-edge as a square rectangle. `InsetTableRowView`
    // below draws that shape directly instead, matching the sidebar's `.sourceList` look, so the
    // base style stays `.plain`. `intercellSpacing` stays zeroed since row spacing is fully
    // controlled by `tableView(_:heightOfRow:)` below.
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

  private func sortMenuIconName(for field: PasswordItemSortField) -> String {
    switch field {
    case .title: return "textformat"
    case .website: return "safari"
    case .createdAt: return "plus.circle"
    case .modifiedAt: return "pencil.line"
    }
  }

  private func sortMenuTitle(for direction: SortDirection) -> String {
    switch direction {
    case .ascending: return "Ascending"
    case .descending: return "Descending"
    }
  }

  /// Matches Apple Passwords' own sort menu (`sort-menu-dark.png`): Ascending pairs with
  /// `arrow.down` and Descending with `arrow.up`, not the more "obvious" reverse pairing.
  private func sortMenuIconName(for direction: SortDirection) -> String {
    switch direction {
    case .ascending: return "arrow.down"
    case .descending: return "arrow.up"
    }
  }

  // MARK: Row computation

  private func rebuildRows(preservingSelection: Bool) {
    let previouslySelectedIDs = preservingSelection ? Set(selectedItems().map(\.id)) : []

    rows = computeRows()
    tableView.deselectAll(nil)
    tableView.reloadData()

    if !previouslySelectedIDs.isEmpty {
      let indices = rows.indices.filter { previouslySelectedIDs.contains(rows[$0].id) }
      if !indices.isEmpty {
        tableView.selectRowIndexes(IndexSet(indices), byExtendingSelection: false)
      }
    }

    updateEmptyState()
    updateListTitle()
  }

  private func computeRows() -> [PasswordItem] {
    let filtered = dataSource.items.filter { currentCategory.matches($0) }

    guard searchQuery.isEmpty else {
      return rankedRows(from: filtered)
    }

    return filtered.sorted(by: PasswordItem.sortComparator(for: sortField, direction: sortDirection))
  }

  private func rankedRows(from items: [PasswordItem]) -> [PasswordItem] {
    items.compactMap { item -> (PasswordItem, Double)? in
      guard let score = item.searchScore(for: searchQuery) else { return nil }
      return (item, score)
    }
    .sorted { lhs, rhs in
      lhs.1 == rhs.1 ? lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending : lhs.1 > rhs.1
    }
    .map(\.0)
  }

  private func updateEmptyState() {
    let hasItems = !rows.isEmpty
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

  private func updateListTitle() {
    let subtitle = rows.count == 1 ? "1 Item" : "\(rows.count) Items"
    listTitleView?.configure(title: currentCategory.title, subtitle: subtitle)
  }

  private func selectedItems() -> [PasswordItem] {
    tableView.selectedRowIndexes.compactMap { index in
      rows.indices.contains(index) ? rows[index] : nil
    }
  }

  private func updateSortMenuCheckmarks() {
    for item in sortMenu.items {
      if let field = item.representedObject as? PasswordItemSortField {
        item.state = field == sortField ? .on : .off
      } else if let direction = item.representedObject as? SortDirection {
        item.state = direction == sortDirection ? .on : .off
      }
    }
  }

  // MARK: Actions

  @objc private func selectSortField(_ sender: NSMenuItem) {
    guard let field = sender.representedObject as? PasswordItemSortField, field != sortField else { return }
    sortField = field
    updateSortMenuCheckmarks()
    rebuildRows(preservingSelection: true)
  }

  @objc private func selectSortDirection(_ sender: NSMenuItem) {
    guard let direction = sender.representedObject as? SortDirection, direction != sortDirection else { return }
    sortDirection = direction
    updateSortMenuCheckmarks()
    rebuildRows(preservingSelection: true)
  }

  @objc private func copyUsername(_ sender: Any?) {
    guard let item = selectedItems().first, selectedItems().count == 1,
      let username = item.usernames.first(where: { !$0.isEmpty })
    else { return }
    Pasteboard.copySecret(username)
  }

  @objc private func copyPassword(_ sender: Any?) {
    let items = selectedItems()
    guard items.count == 1, !items[0].password.isEmpty else { return }
    Pasteboard.copySecret(items[0].password)
  }

  @objc private func copyVerificationCode(_ sender: Any?) {
    let items = selectedItems()
    guard items.count == 1, let totp = items[0].totp else { return }
    Pasteboard.copySecret(totp.code())
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
    let cell = ItemRowCellView.dequeue(from: tableView, owner: self)
    cell.configure(with: rows[row], hidesSeparator: hidesSeparator(atRow: row))
    return cell
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    // Tall enough for the 40pt icon plus vertical breathing room, matching Apple Passwords
    // (851-2463) — up from 40pt before this ticket's icons grew from 28pt.
    56
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    InsetTableRowView()
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    delegate?.itemListViewController(self, didChangeSelection: selectedItems())
    updateSeparatorVisibility()
  }

  /// Whether row `row`'s own hairline (drawn at its bottom edge) should be hidden: either because
  /// `row` itself is selected (hides the separator "below" it), or because `row + 1` is selected
  /// (hides the separator "above" that row, which is this row's bottom edge) — matching Apple
  /// Passwords, which never draws a hairline through a rounded selection highlight (851-2463).
  private func hidesSeparator(atRow row: Int) -> Bool {
    let selected = tableView.selectedRowIndexes
    return selected.contains(row) || selected.contains(row + 1)
  }

  /// Re-applies `hidesSeparator(atRow:)` to every currently on-screen row. Selection changes don't
  /// re-invoke `tableView(_:viewFor:row:)` on their own, so without this, a row's hairline
  /// wouldn't update until it was scrolled off-screen and back (or the table reloaded) after its
  /// neighbor's selection state changed.
  private func updateSeparatorVisibility() {
    for row in rows.indices {
      guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ItemRowCellView else {
        continue
      }
      cell.setSeparatorHidden(hidesSeparator(atRow: row))
    }
  }
}

extension ItemListViewController: NSMenuDelegate {
  func menuNeedsUpdate(_ menu: NSMenu) {
    let clickedRow = tableView.clickedRow
    guard clickedRow >= 0, rows.indices.contains(clickedRow) else {
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

extension ItemListViewController: NSSearchFieldDelegate {
  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSSearchField else { return }
    updateSearch(query: field.stringValue)
  }

  /// Called when the user presses Esc or clicks the field's cancel button in the toolbar's search
  /// field — `NSSearchField` already clears its own text for both, this just makes sure the query
  /// (and results) reset to match, satisfying "Esc clears it" (851-2461).
  func searchFieldDidEndSearching(_ sender: NSSearchField) {
    updateSearch(query: "")
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

/// A row view that draws its own rounded, inset selection highlight — matching the sidebar's
/// `.sourceList` look — since `NSTableView.Style.inset` doesn't produce that shape by itself for a
/// plain single-column table view (see `configureTableView()` above for why).
private final class InsetTableRowView: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    guard selectionHighlightStyle != .none else { return }
    let insetRect = bounds.insetBy(dx: 8, dy: 1)
    let path = NSBezierPath(roundedRect: insetRect, xRadius: 6, yRadius: 6)
    (isEmphasized ? NSColor.controlAccentColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
    path.fill()
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
