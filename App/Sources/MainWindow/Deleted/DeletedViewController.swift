import AppKit
import Combine
import LilPasswordsKit

/// The Deleted view (851-2420): every item in "Recently Deleted", soonest-to-expire first, each
/// showing how many days remain before `VaultViewModel`'s daily purge erases it for good. Per-row
/// Recover/Delete Permanently (both duplicated in a right-click context menu), plus header-level
/// "Recover All"/"Delete All" bulk actions — Delete Permanently (single or bulk) always confirms
/// first, since it's unrecoverable.
///
/// Swapped in for `DetailViewController` (full column width) whenever the sidebar's Deleted
/// category is selected; see `MainSplitViewController`.
@MainActor
final class DeletedViewController: NSViewController {
  private let dataSource: VaultViewModel
  private var cancellable: AnyCancellable?
  private var items: [PasswordItem] = []

  private let headerBar = NSView()
  private let countLabel = NSTextField(labelWithString: "")
  private let recoverAllButton = NSButton()
  private let deleteAllButton = NSButton()
  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private let emptyStateView = EmptyStateView()

  private let contextMenu = NSMenu()
  private let recoverMenuItem = NSMenuItem(title: "Recover", action: nil, keyEquivalent: "")
  private let deleteMenuItem = NSMenuItem(title: "Delete Permanently", action: nil, keyEquivalent: "")

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
    emptyStateView.isHidden = true

    view.addSubview(headerBar)
    view.addSubview(scrollView)
    view.addSubview(emptyStateView)

    headerBar.translatesAutoresizingMaskIntoConstraints = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    emptyStateView.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      headerBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      headerBar.heightAnchor.constraint(equalToConstant: 36),

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
    recoverAllButton.title = "Recover All"
    recoverAllButton.bezelStyle = .rounded
    recoverAllButton.controlSize = .small
    recoverAllButton.target = self
    recoverAllButton.action = #selector(recoverAllTapped)

    deleteAllButton.translatesAutoresizingMaskIntoConstraints = false
    deleteAllButton.title = "Delete All"
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

  private func rebuildRows() {
    items = dataSource.items.recentlyDeleted().sortedByDaysRemaining()
    tableView.reloadData()

    countLabel.stringValue = items.count == 1 ? "1 Item" : "\(items.count) Items"
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
  }

  // MARK: - Per-row actions

  private func recover(_ item: PasswordItem) {
    dataSource.restore(item)
  }

  private func confirmAndDeletePermanently(_ items: [PasswordItem], in window: NSWindow) {
    guard !items.isEmpty else { return }
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText =
      items.count == 1 ? "Delete “\(items[0].title)” Permanently?" : "Delete \(items.count) Items Permanently?"
    alert.informativeText = "This can't be undone."
    alert.addButton(withTitle: "Delete Permanently")
    alert.addButton(withTitle: "Cancel")
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
      dataSource.restore(item)
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
    cell.onRecoverTapped = { [weak self] in self?.recover(item) }
    cell.onDeletePermanentlyTapped = { [weak self] in
      guard let self, let window = self.view.window else { return }
      self.confirmAndDeletePermanently([item], in: window)
    }
    return cell
  }
}

extension DeletedViewController: NSMenuDelegate {
  func menuNeedsUpdate(_ menu: NSMenu) {
    let enabled = clickedItem() != nil
    recoverMenuItem.isEnabled = enabled
    deleteMenuItem.isEnabled = enabled
  }
}
