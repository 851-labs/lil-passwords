import AppKit
import Combine
import LilPasswordsKit

/// The Security view (851-2419): every non-deleted, non-hidden item flagged by
/// ``SecurityAuditor``, grouped by issue ("Compromised Passwords", "Reused Passwords", "Weak
/// Passwords"), each row offering "Change Password on Website" and "Hide Security Warning".
/// Hiding a finding drops that row immediately (`SecurityFindings` excludes items with
/// `securityWarningHidden`), and the sidebar badge (`VaultSnapshot`) tracks the same count this
/// view lists.
///
/// "Compromised Passwords" (851-2458) is populated asynchronously and only when
/// `AppSettings.detectCompromisedPasswords` is on: `CompromisedPasswordChecker` runs in this (the
/// app) process, never the helper, sending only a 5-character hash prefix per unique password to
/// Have I Been Pwned. The other two groups stay fully on-device and synchronous via
/// `SecurityAuditor`, so rows appear immediately and the compromised group fills in — or is simply
/// never added — once (and if) that lookup finishes.
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
  private let compromisedChecker: CompromisedPasswordChecker
  private var cancellable: AnyCancellable?
  private var rows: [Row] = []
  private var itemsByID: [UUID: PasswordItem] = [:]
  /// The table's width the last time row heights were computed for it — `heightOfRow` wraps
  /// each finding's reason text to this width (851-2426), so a resize (which changes where that
  /// text wraps) must invalidate the cached heights, not just leave the old ones in place.
  private var lastKnownTableWidth: CGFloat = 0
  private var currentItems: [PasswordItem] = []
  private var compromisedIDs: Set<UUID> = []
  private var compromisedCheckTask: Task<Void, Never>?
  private var settingsObserver: NSObjectProtocol?
  /// The exact `(id, password)` pairs the current/most recently started `compromisedCheckTask` was
  /// kicked off for — lets ``refreshCompromisedStatusIfNeeded()`` tell a genuine vault change from
  /// a benign re-emission of `dataSource.itemsDidChange` carrying the same items (observed during
  /// startup/seeding, where the publisher can fire more than once in quick succession). Without
  /// this, every re-emission would cancel and restart the HIBP lookup from scratch, and with
  /// enough items (each unique password prefix rate-limited 1.5s apart) it could keep getting
  /// restarted before ever surviving to completion.
  private var lastCheckedPasswordsByID: [UUID: String]?

  private let headerBar = NSView()
  private let countLabel = NSTextField(labelWithString: "")
  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private let emptyStateView = EmptyStateView()

  init(dataSource: VaultViewModel, compromisedChecker: CompromisedPasswordChecker = CompromisedPasswordChecker()) {
    self.dataSource = dataSource
    self.compromisedChecker = compromisedChecker
    super.init(nibName: nil, bundle: nil)
  }

  isolated deinit {
    compromisedCheckTask?.cancel()
    if let settingsObserver {
      NotificationCenter.default.removeObserver(settingsObserver)
    }
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
      .sink { [weak self] in self?.itemsDidChange() }
    settingsObserver = NotificationCenter.default.addObserver(
      forName: AppSettings.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refreshCompromisedStatusIfNeeded() }
    }
    itemsDidChange()
  }

  private func itemsDidChange() {
    currentItems = dataSource.items
    itemsByID = Dictionary(uniqueKeysWithValues: currentItems.map { ($0.id, $0) })
    rebuildRows()
    refreshCompromisedStatusIfNeeded()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    let width = tableView.bounds.width
    guard width != lastKnownTableWidth else { return }
    lastKnownTableWidth = width
    tableView.noteHeightOfRows(withIndexesChanged: IndexSet(rows.indices))
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
    let findings = SecurityFindings.build(from: currentItems, compromisedIDs: compromisedIDs)
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
    countLabel.stringValue = count == 1 ? String(localized: "1 Item") : String(localized: "\(count) Items")

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

  /// Kicks off (or cancels) the async, opt-in Have I Been Pwned lookup for the current items.
  ///
  /// Only ``rebuildRows()`` runs synchronously off `currentItems`/``compromisedIDs`` — this method
  /// never calls it recursively on its own account beyond the one completion update below, so
  /// toggling the setting or the vault contents changing can't spin up overlapping refresh loops.
  /// A re-entrant call carrying the exact same `(id, password)` pairs as the in-flight/most recent
  /// call is a no-op — see ``lastCheckedPasswordsByID``.
  private func refreshCompromisedStatusIfNeeded() {
    guard AppSettings.shared.detectCompromisedPasswords else {
      compromisedCheckTask?.cancel()
      compromisedCheckTask = nil
      lastCheckedPasswordsByID = nil
      if !compromisedIDs.isEmpty {
        compromisedIDs = []
        rebuildRows()
      }
      return
    }

    let items = currentItems
    let passwordsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.password) })
    guard passwordsByID != lastCheckedPasswordsByID else { return }
    lastCheckedPasswordsByID = passwordsByID

    compromisedCheckTask?.cancel()
    let checker = compromisedChecker
    compromisedCheckTask = Task { @MainActor [weak self] in
      let inputs = items.map { CompromisedPasswordChecker.Input(id: $0.id, password: $0.password) }
      let ids = await checker.check(inputs)
      guard !Task.isCancelled, let self else { return }
      self.compromisedIDs = ids
      self.rebuildRows()
    }
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
    case .finding(_, let kind):
      return SecurityFindingRowCellView.height(for: kind, availableWidth: tableView.bounds.width)
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
