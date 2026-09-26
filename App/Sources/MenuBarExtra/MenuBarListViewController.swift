import AppKit
import Combine
import LilPasswordsKit

@MainActor
protocol MenuBarListViewControllerDelegate: AnyObject {
  func menuBarListViewController(_ controller: MenuBarListViewController, didSelect item: PasswordItem)
  func menuBarListViewControllerDidRequestOpenApp(_ controller: MenuBarListViewController)
}

/// The popover's main content (851-2425): a focused search field, a "Suggested" section for the
/// frontmost browser's current site (851-2425's ``BrowserSuggestionProvider``, off by default),
/// then fuzzy search results — matching Apple Passwords' own menu bar extra. Built the same way
/// as `ItemListViewController` (851-2417): an `NSTableView` over a small `Row` enum recomputed on
/// every relevant change, section headers reusing `SectionHeaderCellView`, item rows reusing
/// `CredentialRowView` and `PasswordItem.searchScore(for:)` for ranking.
@MainActor
final class MenuBarListViewController: NSViewController {
  private enum Row {
    case section(String)
    case item(PasswordItem)
  }

  private let vaultViewModel: VaultViewModel
  private var itemsDidChangeCancellable: AnyCancellable?

  private var searchQuery: String = ""
  private var rows: [Row] = []

  weak var delegate: MenuBarListViewControllerDelegate?

  private let searchField = NSSearchField()
  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private let emptyStateField = NSTextField(labelWithString: String(localized: "No Passwords"))
  private let footerButton = NSButton()

  init(vaultViewModel: VaultViewModel) {
    self.vaultViewModel = vaultViewModel
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func loadView() {
    let view = NSView()
    configureSearchField()
    configureTableView()
    configureEmptyStateField()
    configureFooter()

    let footerSeparator = NSBox()
    footerSeparator.boxType = .separator
    footerSeparator.translatesAutoresizingMaskIntoConstraints = false

    view.addSubview(searchField)
    view.addSubview(scrollView)
    view.addSubview(emptyStateField)
    view.addSubview(footerSeparator)
    view.addSubview(footerButton)

    searchField.translatesAutoresizingMaskIntoConstraints = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    emptyStateField.translatesAutoresizingMaskIntoConstraints = false
    footerButton.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
      searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
      searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),

      scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor, constant: -4),

      emptyStateField.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
      emptyStateField.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

      footerSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      footerSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      footerSeparator.bottomAnchor.constraint(equalTo: footerButton.topAnchor, constant: -6),

      footerButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
      footerButton.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -10),
      footerButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
    ])

    self.view = view
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    itemsDidChangeCancellable = vaultViewModel.itemsDidChange
      .receive(on: RunLoop.main)
      .sink { [weak self] in self?.rebuildRows() }
    rebuildRows()
  }

  /// Called by `MenuBarRootViewController` each time the popover is about to be shown, so the
  /// "Suggested" section reflects whatever the frontmost browser is showing *right now* rather
  /// than whatever it was the last time the popover opened, and so the search field always starts
  /// focused, matching Apple Passwords.
  func popoverWillShow() {
    rebuildRows()
    view.window?.makeFirstResponder(searchField)
  }

  /// Sets the search field's text and re-filters as if the user had typed it — used by
  /// `MenuBarExtraDebugMenu`'s tophat capture to produce a "searching" screenshot without
  /// simulating real keystrokes.
  func setSearchQuery(_ query: String) {
    searchField.stringValue = query
    updateSearch(query: query)
  }

  private func configureSearchField() {
    searchField.placeholderString = String(localized: "Search Passwords")
    searchField.delegate = self
    searchField.sendsWholeSearchString = false
    searchField.sendsSearchStringImmediately = true
  }

  private func configureTableView() {
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MenuBarItem"))
    column.width = 300
    tableView.addTableColumn(column)
    tableView.headerView = nil
    // `.plain` + `floatsGroupRows` matches `ItemListViewController`'s own table (851-2417) — the
    // default `.automatic` style otherwise resolves to a heavier, `.sourceList`-like group-row
    // treatment here (bold background, full-width divider under "All Passwords") that reads as
    // more "chrome" than the rest of the app, per design review of the first cut's screenshots.
    tableView.style = .plain
    tableView.usesAlternatingRowBackgroundColors = false
    tableView.floatsGroupRows = true
    tableView.intercellSpacing = NSSize(width: 0, height: 0)
    tableView.selectionHighlightStyle = .regular
    tableView.dataSource = self
    tableView.delegate = self
    tableView.target = self
    tableView.doubleAction = #selector(activateSelectedRow)

    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
  }

  private func configureEmptyStateField() {
    emptyStateField.textColor = .secondaryLabelColor
    emptyStateField.font = .systemFont(ofSize: 12)
    emptyStateField.isHidden = true
  }

  private func configureFooter() {
    footerButton.title = String(localized: "Open \(LilPasswordsKit.productName)")
    footerButton.bezelStyle = .accessoryBarAction
    footerButton.controlSize = .small
    footerButton.target = self
    footerButton.action = #selector(openAppTapped)
  }

  // MARK: - Row computation

  private func rebuildRows() {
    rows = computeRows()
    tableView.reloadData()
    let hasItems = rows.contains { if case .item = $0 { return true } else { return false } }
    emptyStateField.isHidden = hasItems
    scrollView.isHidden = !hasItems
    emptyStateField.stringValue =
      searchQuery.isEmpty ? String(localized: "No Passwords") : String(localized: "No Results")
  }

  private func computeRows() -> [Row] {
    let allItems = vaultViewModel.items.filter { $0.deletedAt == nil }

    guard searchQuery.isEmpty else {
      return [Row.section(String(localized: "Results"))] + rankedRows(from: allItems, query: searchQuery)
    }

    var rows: [Row] = []
    let suggestions = suggestedItems(from: allItems)
    if !suggestions.isEmpty {
      rows.append(.section(String(localized: "Suggested")))
      rows.append(contentsOf: suggestions.map(Row.item))
    }

    let remaining = allItems.filter { item in !suggestions.contains { $0.id == item.id } }
      .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    if !remaining.isEmpty {
      rows.append(
        .section(suggestions.isEmpty ? String(localized: "All Passwords") : String(localized: "Other Passwords")))
      rows.append(contentsOf: remaining.map(Row.item))
    }
    return rows
  }

  /// Items matching the frontmost browser's current site (851-2425), or `[]` if the setting is
  /// off, no browser could be read, or nothing matches — see `BrowserSuggestionProvider`.
  private func suggestedItems(from items: [PasswordItem]) -> [PasswordItem] {
    guard let url = BrowserSuggestionProvider.currentBrowserURL() else { return [] }
    return items.filter { $0.matchesHost(of: url) }
  }

  private func rankedRows(from items: [PasswordItem], query: String) -> [Row] {
    items.compactMap { item -> (PasswordItem, Double)? in
      guard let score = item.searchScore(for: query) else { return nil }
      return (item, score)
    }
    .sorted { lhs, rhs in
      lhs.1 == rhs.1 ? lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending : lhs.1 > rhs.1
    }
    .map { Row.item($0.0) }
  }

  private func updateSearch(query: String) {
    guard query != searchQuery else { return }
    searchQuery = query
    rebuildRows()
  }

  private func selectedItem() -> PasswordItem? {
    guard rows.indices.contains(tableView.selectedRow), case .item(let item) = rows[tableView.selectedRow] else {
      return nil
    }
    return item
  }

  // MARK: - Actions

  @objc private func activateSelectedRow() {
    guard let item = selectedItem() else { return }
    delegate?.menuBarListViewController(self, didSelect: item)
  }

  @objc private func openAppTapped() {
    delegate?.menuBarListViewControllerDidRequestOpenApp(self)
  }
}

extension MenuBarListViewController: NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int {
    rows.count
  }
}

extension MenuBarListViewController: NSTableViewDelegate {
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    switch rows[row] {
    case .section(let title):
      let cell = SectionHeaderCellView.dequeue(from: tableView, owner: self)
      cell.configure(title: title)
      return cell
    case .item(let item):
      let cell = CredentialRowView.dequeue(from: tableView, owner: self)
      // The menu bar extra's list doesn't hide separators around the selection the way the main
      // window's item list does (851-2463) — it always shows them.
      cell.configure(with: item, hidesSeparator: false)
      return cell
    }
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    switch rows[row] {
    case .section: return 22
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
    // A single click selects a row (Apple Passwords' own popover behaves the same way — there's
    // no separate "activate" gesture needed since nothing else useful happens on a single-click
    // select in a popover this small), so selection itself is what shows the item's detail.
    activateSelectedRow()
  }
}

extension MenuBarListViewController: NSSearchFieldDelegate {
  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSSearchField else { return }
    updateSearch(query: field.stringValue)
  }

  func searchFieldDidEndSearching(_ sender: NSSearchField) {
    updateSearch(query: "")
  }
}
