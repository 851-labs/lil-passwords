import AppKit
import Combine
import LilPasswordsKit

@MainActor
protocol WiFiListViewControllerDelegate: AnyObject {
  func wifiListViewController(_ controller: WiFiListViewController, didSelect network: WiFiNetwork?)
}

/// The Wi-Fi category's list column: known networks reported by macOS (see
/// `docs/adr/0005-wifi-passwords.md` for where that list comes from), each showing its security
/// type and whether it's the network this Mac is presently on. There's deliberately no "+" add
/// button here the way ``CodesViewController``'s header bar has one — this list only ever reflects
/// networks macOS itself already knows about, not ones a person adds inside this app.
///
/// Matches `ItemListViewController`'s Apple-parity chrome (851-2463, brought here by 851-2444): the
/// category name and network count live in the toolbar (`ListTitleToolbarView`, pushed to it below)
/// instead of an in-content header row, live search filters the list, and selection draws as the
/// same rounded, inset highlight (`InsetTableRowView`) rather than a full-width bar.
@MainActor
final class WiFiListViewController: NSViewController {
  weak var delegate: WiFiListViewControllerDelegate?

  private let viewModel: WiFiNetworkViewModel
  private var cancellable: AnyCancellable?

  /// Every known network, unfiltered — `rows` (below) is this filtered by `searchQuery`.
  private var allNetworks: [WiFiNetwork] = []
  private var searchQuery: String = ""
  private var rows: [WiFiNetwork] = []

  /// The toolbar's search field: owned and laid out by `MainToolbarController`, not here — same
  /// pattern as `ItemListViewController.searchField`. `MainSplitViewController` swaps this
  /// controller in as the field's delegate only while Wi-Fi is the selected sidebar category
  /// (`onSearchDelegateChange`), so query handling can stay here without owning any toolbar UI.
  weak var searchField: NSSearchField?

  /// The toolbar's two-line title ("Wi-Fi" + "N Networks"), pushed to whenever `applyNetworks`/the
  /// search query rebuilds rows. Shared with `ItemListViewController` — only one of the two is
  /// ever the visible category at a time — so `updateListTitle()` below is guarded on this view
  /// actually being on screen (see its doc comment) to avoid clobbering the other's text.
  weak var listTitleView: ListTitleToolbarView?

  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private let emptyStateView = EmptyStateView()

  init(viewModel: WiFiNetworkViewModel) {
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
      // Pinned to the raw view edges, not the safe area guide: the list scrolls *underneath* the
      // translucent unified toolbar rather than stopping below it, matching
      // `ItemListViewController` (851-2463) — no empty band above the list (851-2444 review).
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

    cancellable = viewModel.$networks
      .receive(on: RunLoop.main)
      .sink { [weak self] networks in self?.applyNetworks(networks) }
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    updateListTitle()
    Task { await viewModel.refresh() }
  }

  // MARK: Public API (called by MainSplitViewController / MainWindowController)

  /// Focuses and selects-all in the toolbar's search field, in response to ⌘F, mirroring
  /// `ItemListViewController.focusSearchField()` — `MainWindowController`'s local event monitor
  /// only knows about `ItemListViewController` today because ⌘F is only ever wired to whichever
  /// list is currently visible; nothing here calls this yet, but it exists so a future wiring of
  /// ⌘F-while-Wi-Fi-is-selected has somewhere to forward to.
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
    // See `ItemListViewController.configureTableView()`'s doc comment for why `.plain` +
    // `InsetTableRowView` (rather than `.inset`) is what actually produces the rounded, floating
    // selection highlight this list needs to match (851-2444 review point 2).
    tableView.style = .plain
    tableView.intercellSpacing = NSSize(width: 0, height: 0)
    tableView.dataSource = self
    tableView.delegate = self

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("NetworkColumn"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)

    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
  }

  // MARK: Row computation

  private func applyNetworks(_ networks: [WiFiNetwork]) {
    allNetworks = networks
    rebuildRows()
  }

  private func updateSearch(query: String) {
    guard query != searchQuery else { return }
    searchQuery = query
    rebuildRows()
  }

  private func rebuildRows() {
    let previouslySelectedSSID = selectedNetwork()?.ssid

    rows = filteredNetworks()
    tableView.reloadData()

    if let previouslySelectedSSID, let row = rows.firstIndex(where: { $0.ssid == previouslySelectedSSID }) {
      tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    } else {
      delegate?.wifiListViewController(self, didSelect: nil)
    }

    updateEmptyState()
    updateListTitle()
  }

  private func filteredNetworks() -> [WiFiNetwork] {
    guard !searchQuery.isEmpty else { return allNetworks }
    return allNetworks.filter { $0.ssid.localizedCaseInsensitiveContains(searchQuery) }
  }

  private func updateEmptyState() {
    let hasNetworks = !rows.isEmpty
    scrollView.isHidden = !hasNetworks
    emptyStateView.isHidden = hasNetworks
    guard !hasNetworks else { return }

    if !searchQuery.isEmpty {
      emptyStateView.configure(
        symbolName: "magnifyingglass",
        title: String(localized: "No Results"),
        message: String(localized: "Try a different search.")
      )
    } else {
      emptyStateView.configure(
        symbolName: SidebarCategory.wifi.symbolName,
        title: SidebarCategory.wifi.emptyListTitle,
        message: SidebarCategory.wifi.emptyListMessage
      )
    }
  }

  /// Pushes "Wi-Fi" + "N Networks" into the shared toolbar title — but only while this list is
  /// actually the one on screen. `WiFiListViewController` and `ItemListViewController` share one
  /// `listTitleView` (only one is ever visible at a time, per `MainSplitViewController`'s
  /// container-swap), and `viewModel.refresh()` (the only thing that republishes `$networks`, see
  /// `WiFiNetworkViewModel`) only ever runs from this controller's own `viewWillAppear()` — so a
  /// stale publish landing after the sidebar has already switched away can't normally happen, but
  /// this guard keeps that true even if a future caller starts refreshing off-screen.
  private func updateListTitle() {
    guard isViewLoaded, view.window != nil else { return }
    let count = rows.count
    let subtitle = count == 1 ? String(localized: "1 Network") : String(localized: "\(count) Networks")
    listTitleView?.configure(title: SidebarCategory.wifi.title, subtitle: subtitle)
  }

  private func selectedNetwork() -> WiFiNetwork? {
    guard tableView.selectedRow >= 0, tableView.selectedRow < rows.count else { return nil }
    return rows[tableView.selectedRow]
  }

  /// Whether row `row`'s own hairline (drawn at its bottom edge) should be hidden: either because
  /// `row` itself is selected (hides the separator "below" it), or because `row + 1` is selected
  /// (hides the separator "above" that row, which is this row's bottom edge) — matching
  /// `ItemListViewController`, which never draws a hairline through a rounded selection highlight.
  private func hidesSeparator(atRow row: Int) -> Bool {
    let selected = tableView.selectedRowIndexes
    return selected.contains(row) || selected.contains(row + 1)
  }

  /// Re-applies `hidesSeparator(atRow:)` to every currently on-screen row — see
  /// `ItemListViewController.updateSeparatorVisibility()`'s doc comment for why this is needed on
  /// top of `configure(with:hidesSeparator:)` alone.
  private func updateSeparatorVisibility() {
    for row in rows.indices {
      guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? WiFiNetworkRowCellView else {
        continue
      }
      cell.setSeparatorHidden(hidesSeparator(atRow: row))
    }
  }
}

extension WiFiListViewController: NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int {
    rows.count
  }
}

extension WiFiListViewController: NSTableViewDelegate {
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let cell = WiFiNetworkRowCellView.dequeue(from: tableView, owner: self)
    cell.configure(with: rows[row], hidesSeparator: hidesSeparator(atRow: row))
    return cell
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    // Matches `ItemListViewController`'s row height (851-2463/851-2444), same row metrics across
    // both lists.
    56
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    InsetTableRowView()
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    delegate?.wifiListViewController(self, didSelect: selectedNetwork())
    updateSeparatorVisibility()
  }
}

extension WiFiListViewController: NSSearchFieldDelegate {
  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSSearchField else { return }
    updateSearch(query: field.stringValue)
  }

  /// Called when the user presses Esc or clicks the field's cancel button in the toolbar's search
  /// field — mirrors `ItemListViewController.searchFieldDidEndSearching(_:)`.
  func searchFieldDidEndSearching(_ sender: NSSearchField) {
    updateSearch(query: "")
  }
}
