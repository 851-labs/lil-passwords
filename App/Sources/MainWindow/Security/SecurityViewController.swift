import AppKit
import Combine
import LilPasswordsKit

/// The Security view (851-2419): every non-deleted, non-hidden item flagged by
/// ``SecurityAuditor``, grouped by issue ("Reused Passwords", "Weak Passwords" — "Compromised" is
/// deferred to a later Have I Been Pwned ticket), each row offering "Change Password on Website"
/// and "Hide Security Warning". Hiding a finding drops that row immediately (`SecurityFindings`
/// excludes items with `securityWarningHidden`), and the sidebar badge (`VaultSnapshot`) tracks
/// the same count this view lists.
///
/// Swapped in for `DetailViewController` (full column width) whenever the sidebar's Security
/// category is selected; see `MainSplitViewController`.
@MainActor
final class SecurityViewController: NSViewController {
  private enum Row {
    case section(String)
    case finding(itemID: UUID, kind: SecurityIssueKind)
  }

  private let dataSource: VaultViewModel
  private var cancellable: AnyCancellable?
  private var rows: [Row] = []
  private var itemsByID: [UUID: PasswordItem] = [:]

  private let headerBar = NSView()
  private let countLabel = NSTextField(labelWithString: "")
  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private let emptyStateView = EmptyStateView()

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

    headerBar.addSubview(countLabel)
    NSLayoutConstraint.activate([
      countLabel.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 16),
      countLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
    ])
  }

  private func configureTableView() {
    tableView.headerView = nil
    tableView.usesAlternatingRowBackgroundColors = false
    tableView.allowsMultipleSelection = false
    tableView.allowsEmptySelection = true
    tableView.floatsGroupRows = true
    tableView.style = .plain
    tableView.intercellSpacing = NSSize(width: 0, height: 0)
    tableView.dataSource = self
    tableView.delegate = self

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SecurityColumn"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)

    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
  }

  private func rebuildRows() {
    let items = dataSource.items
    itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

    let findings = SecurityFindings.build(from: items)
    var newRows: [Row] = []
    for group in findings.groups {
      newRows.append(.section(group.kind.groupTitle))
      for itemID in group.itemIDs {
        newRows.append(.finding(itemID: itemID, kind: group.kind))
      }
    }
    rows = newRows
    tableView.reloadData()

    let count = findings.uniqueItemIDs.count
    countLabel.stringValue = count == 1 ? "1 Item" : "\(count) Items"

    let hasFindings = !newRows.isEmpty
    scrollView.isHidden = !hasFindings
    emptyStateView.isHidden = hasFindings
    if !hasFindings {
      emptyStateView.configure(
        symbolName: SidebarCategory.security.symbolName,
        title: SidebarCategory.security.emptyListTitle,
        message: SidebarCategory.security.emptyListMessage
      )
    }
  }

  private func hideWarning(for itemID: UUID) {
    guard var item = itemsByID[itemID] else { return }
    item.securityWarningHidden = true
    item.modifiedAt = Date()
    dataSource.save(item)
  }
}

extension SecurityViewController: NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int {
    rows.count
  }
}

extension SecurityViewController: NSTableViewDelegate {
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    switch rows[row] {
    case .section(let title):
      let cell = SectionHeaderCellView.dequeue(from: tableView, owner: self)
      cell.configure(title: title)
      return cell
    case .finding(let itemID, let kind):
      guard let item = itemsByID[itemID] else { return nil }
      let cell = SecurityFindingRowCellView.dequeue(from: tableView, owner: self)
      cell.configure(item: item, kind: kind)
      cell.onChangePasswordTapped = { [weak self] in
        self?.openChangePasswordPage(for: itemID)
      }
      cell.onHideWarningTapped = { [weak self] in
        self?.hideWarning(for: itemID)
      }
      return cell
    }
  }

  private func openChangePasswordPage(for itemID: UUID) {
    guard let item = itemsByID[itemID], let url = item.changePasswordURL else { return }
    NSWorkspace.shared.open(url)
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    switch rows[row] {
    case .section: return 28
    case .finding: return 122
    }
  }

  func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
    if case .section = rows[row] { return true }
    return false
  }

  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    false
  }
}
