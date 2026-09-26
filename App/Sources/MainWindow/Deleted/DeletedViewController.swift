import AppKit
import Combine
import LilPasswordsKit

/// The Deleted view (851-2420): every item in "Recently Deleted", soonest-to-expire first, each
/// showing how many days remain before `VaultViewModel`'s daily purge erases it for good.
///
/// 851-2426's review note asked for the original per-row Recover/Delete Permanently buttons
/// (still duplicated in a right-click context menu) to go away in favor of a context menu plus a
/// detail pane, matching Apple Passwords' own, lighter-weight row style — so this now lays out an
/// internal list/detail split (`DeletedDetailView`) rather than putting buttons on every row.
/// Header-level "Recover All"/"Delete All" bulk actions remain, spanning both panes above the
/// split. Delete Permanently (single, bulk, or from the detail pane's multi-selection state)
/// always confirms first, since it's unrecoverable.
///
/// Swapped in for `DetailViewController` (full column width) whenever the sidebar's Deleted
/// category is selected; see `MainSplitViewController`. This is a self-contained internal split
/// rather than a change to `MainSplitViewController`'s own list/detail wiring, so the other
/// full-width categories (Codes, Security) aren't affected.
@MainActor
final class DeletedViewController: NSViewController {
  private let dataSource: VaultViewModel
  private var cancellable: AnyCancellable?
  private var items: [PasswordItem] = []

  private let headerBar = NSView()
  private let countLabel = NSTextField(labelWithString: "")
  private let recoverAllButton = NSButton()
  private let deleteAllButton = NSButton()
  private let splitView = NSSplitView()
  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private let emptyStateView = EmptyStateView()
  private let detailView = DeletedDetailView()

  private let contextMenu = NSMenu()
  private let recoverMenuItem = NSMenuItem(title: String(localized: "Recover"), action: nil, keyEquivalent: "")
  private let deleteMenuItem = NSMenuItem(
    title: String(localized: "Delete Permanently"),
    action: nil,
    keyEquivalent: ""
  )

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
    configureDetailPane()
    emptyStateView.isHidden = true

    let listContainer = NSView()
    listContainer.translatesAutoresizingMaskIntoConstraints = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    emptyStateView.translatesAutoresizingMaskIntoConstraints = false
    listContainer.addSubview(scrollView)
    listContainer.addSubview(emptyStateView)
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: listContainer.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),

      emptyStateView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
      emptyStateView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
      emptyStateView.topAnchor.constraint(equalTo: listContainer.topAnchor),
      emptyStateView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
    ])

    splitView.translatesAutoresizingMaskIntoConstraints = false
    splitView.isVertical = true
    splitView.dividerStyle = .thin
    splitView.delegate = self
    splitView.addArrangedSubview(listContainer)
    splitView.addArrangedSubview(detailView)
    splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)

    view.addSubview(headerBar)
    view.addSubview(splitView)

    headerBar.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      headerBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      headerBar.heightAnchor.constraint(equalToConstant: 36),

      splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      splitView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
      splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    self.view = view
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    cancellable = dataSource.itemsDidChange
      .receive(on: RunLoop.main)
      .sink { [weak self] in self?.rebuildRows() }
    rebuildRows()
  }

  private func configureHeaderBar() {
    countLabel.translatesAutoresizingMaskIntoConstraints = false
    countLabel.font = .systemFont(ofSize: 11)
    countLabel.textColor = .secondaryLabelColor

    recoverAllButton.translatesAutoresizingMaskIntoConstraints = false
    recoverAllButton.title = String(localized: "Recover All")
    recoverAllButton.bezelStyle = .rounded
    recoverAllButton.controlSize = .small
    recoverAllButton.target = self
    recoverAllButton.action = #selector(recoverAllTapped)

    deleteAllButton.translatesAutoresizingMaskIntoConstraints = false
    deleteAllButton.title = String(localized: "Delete All")
    deleteAllButton.bezelStyle = .rounded
    deleteAllButton.controlSize = .small
    deleteAllButton.contentTintColor = .systemRed
    deleteAllButton.target = self
    deleteAllButton.action = #selector(deleteAllTapped)

    headerBar.addSubview(countLabel)
    headerBar.addSubview(deleteAllButton)
    headerBar.addSubview(recoverAllButton)
    NSLayoutConstraint.activate([
      countLabel.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 16),
      countLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

      deleteAllButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -12),
      deleteAllButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

      recoverAllButton.trailingAnchor.constraint(equalTo: deleteAllButton.leadingAnchor, constant: -8),
      recoverAllButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
    ])
  }

  private func configureTableView() {
    tableView.headerView = nil
    tableView.usesAlternatingRowBackgroundColors = false
    tableView.allowsMultipleSelection = true
    tableView.allowsEmptySelection = true
    tableView.style = .plain
    tableView.intercellSpacing = NSSize(width: 0, height: 0)
    tableView.rowHeight = 44
    tableView.dataSource = self
    tableView.delegate = self

    recoverMenuItem.target = self
    recoverMenuItem.action = #selector(recoverClickedRow)
    deleteMenuItem.target = self
    deleteMenuItem.action = #selector(deletePermanentlyClickedRow)
    contextMenu.delegate = self
    contextMenu.addItem(recoverMenuItem)
    contextMenu.addItem(deleteMenuItem)
    tableView.menu = contextMenu

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("DeletedColumn"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)

    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
  }

  private func configureDetailPane() {
    detailView.onRecoverTapped = { [weak self] in
      guard let self else { return }
      for item in self.selectedItems() {
        self.recover(item)
      }
    }
    detailView.onDeletePermanentlyTapped = { [weak self] in
      guard let self, let window = self.view.window else { return }
      self.confirmAndDeletePermanently(self.selectedItems(), in: window)
    }
  }

  private func rebuildRows() {
    let selectedIDs = Set(selectedItems().map(\.id))
    items = dataSource.items.recentlyDeleted().sortedByDaysRemaining()
    tableView.reloadData()

    let indices = IndexSet(items.indices.filter { selectedIDs.contains(items[$0].id) })
    if indices.isEmpty {
      tableView.deselectAll(nil)
    } else {
      tableView.selectRowIndexes(indices, byExtendingSelection: false)
    }

    countLabel.stringValue = items.count == 1 ? String(localized: "1 Item") : String(localized: "\(items.count) Items")
    recoverAllButton.isEnabled = !items.isEmpty
    deleteAllButton.isEnabled = !items.isEmpty

    let hasItems = !items.isEmpty
    scrollView.isHidden = !hasItems
    emptyStateView.isHidden = hasItems
    if !hasItems {
      emptyStateView.configure(
        symbolName: SidebarCategory.deleted.symbolName,
        title: SidebarCategory.deleted.emptyListTitle,
        message: SidebarCategory.deleted.emptyListMessage
      )
    }

    updateDetailPane()
  }

  private func updateDetailPane() {
    let selected = selectedItems()
    if selected.isEmpty {
      detailView.showNoSelection()
    } else if selected.count == 1 {
      detailView.show(item: selected[0], now: Date())
    } else {
      detailView.showMultipleSelection(count: selected.count)
    }
  }

  private func selectedItems() -> [PasswordItem] {
    tableView.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0] : nil }
  }

  // MARK: - Actions

  private func recover(_ item: PasswordItem) {
    dataSource.restore(item)
  }

  private func confirmAndDeletePermanently(_ items: [PasswordItem], in window: NSWindow) {
    guard !items.isEmpty else { return }
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText =
      items.count == 1
      ? String(localized: "Delete “\(items[0].title)” Permanently?")
      : String(localized: "Delete \(items.count) Items Permanently?")
    alert.informativeText = String(localized: "This can't be undone.")
    alert.addButton(withTitle: String(localized: "Delete Permanently"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn else { return }
      for item in items {
        self?.dataSource.deletePermanently(item)
      }
    }
  }

  @objc
  private func recoverAllTapped() {
    for item in items {
      recover(item)
    }
  }

  @objc
  private func deleteAllTapped() {
    guard let window = view.window else { return }
    confirmAndDeletePermanently(items, in: window)
  }

  @objc
  private func recoverClickedRow() {
    guard let item = clickedItem() else { return }
    recover(item)
  }

  @objc
  private func deletePermanentlyClickedRow() {
    guard let item = clickedItem(), let window = view.window else { return }
    confirmAndDeletePermanently([item], in: window)
  }

  private func clickedItem() -> PasswordItem? {
    let row = tableView.clickedRow
    guard items.indices.contains(row) else { return nil }
    return items[row]
  }
}

extension DeletedViewController: NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int {
    items.count
  }
}

extension DeletedViewController: NSTableViewDelegate {
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard items.indices.contains(row) else { return nil }
    let item = items[row]
    let cell = DeletedItemRowCellView.dequeue(from: tableView, owner: self)
    cell.configure(with: item, now: Date())
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    updateDetailPane()
  }
}

extension DeletedViewController: NSMenuDelegate {
  func menuNeedsUpdate(_ menu: NSMenu) {
    let enabled = clickedItem() != nil
    recoverMenuItem.isEnabled = enabled
    deleteMenuItem.isEnabled = enabled
  }
}

extension DeletedViewController: NSSplitViewDelegate {
  func splitView(
    _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int
  ) -> CGFloat {
    220
  }

  func splitView(
    _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int
  ) -> CGFloat {
    guard let width = splitView.superview?.bounds.width else { return proposedMaximumPosition }
    return width - 260
  }
}
