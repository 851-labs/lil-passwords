import AppKit
import Combine
import LilPasswordsKit

/// The Codes view (851-2418): every item with a verification code, showing its live 6/8-digit
/// code and countdown, alphabetically sectioned like the main item list. Clicking a row copies
/// its current code. The header's "+" button opens ``AddVerificationCodeSheetController`` to
/// attach a new code to an item via setup key, QR image file, or a screen scan.
///
/// Swapped in for `DetailViewController` (full column width — there's no separate list/detail
/// split for this category) whenever the sidebar's Codes category is selected; see
/// `MainSplitViewController`.
@MainActor
final class CodesViewController: NSViewController {
  private enum Row {
    case section(String)
    case item(PasswordItem)
  }

  private let dataSource: VaultViewModel
  private var cancellable: AnyCancellable?
  private var tickTimer: Timer?
  private var rows: [Row] = []

  private let headerBar = NSView()
  private let countLabel = NSTextField(labelWithString: "")
  private let addButton = NSButton()
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

  override func viewWillAppear() {
    super.viewWillAppear()
    startTicking()
  }

  override func viewDidDisappear() {
    super.viewDidDisappear()
    tickTimer?.invalidate()
    tickTimer = nil
  }

  private func configureHeaderBar() {
    countLabel.translatesAutoresizingMaskIntoConstraints = false
    countLabel.font = .systemFont(ofSize: 11)
    countLabel.textColor = .secondaryLabelColor

    addButton.translatesAutoresizingMaskIntoConstraints = false
    addButton.bezelStyle = .texturedRounded
    addButton.isBordered = false
    addButton.image = NSImage(
      systemSymbolName: "plus.circle",
      accessibilityDescription: String(localized: "Add Verification Code")
    )
    addButton.imagePosition = .imageOnly
    addButton.target = self
    addButton.action = #selector(addVerificationCode(_:))
    addButton.toolTip = String(localized: "Add Verification Code")
    addButton.setAccessibilityLabel(String(localized: "Add Verification Code"))

    headerBar.addSubview(countLabel)
    headerBar.addSubview(addButton)
    NSLayoutConstraint.activate([
      countLabel.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 16),
      countLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

      addButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -12),
      addButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
      addButton.widthAnchor.constraint(equalToConstant: 22),
      addButton.heightAnchor.constraint(equalToConstant: 22),
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

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("CodeColumn"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)

    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
  }

  private func startTicking() {
    tickTimer?.invalidate()
    tick()
    tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
  }

  /// Refreshes the code/countdown of every currently-visible row in place, without reloading the
  /// table (which would disturb selection and any in-flight "Copied" flash).
  private func tick() {
    let now = Date()
    let visible = tableView.rows(in: tableView.visibleRect)
    guard visible.location != NSNotFound else { return }
    for row in visible.location..<(visible.location + visible.length) {
      guard rows.indices.contains(row), case .item(let item) = rows[row], let totp = item.totp,
        let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? CodeRowCellView
      else { continue }
      cell.updateLiveValues(totp: totp, at: now)
    }
  }

  private func rebuildRows() {
    let items = dataSource.items.withVerificationCode().sorted(
      by: PasswordItem.sortComparator(for: .title, direction: .ascending))
    var newRows: [Row] = []
    var lastKey: String?
    for item in items {
      let key = item.titleSectionKey
      if key != lastKey {
        newRows.append(.section(key))
        lastKey = key
      }
      newRows.append(.item(item))
    }
    rows = newRows
    tableView.reloadData()

    let count = items.count
    countLabel.stringValue = count == 1 ? String(localized: "1 Code") : String(localized: "\(count) Codes")

    let hasItems = !items.isEmpty
    headerBar.isHidden = false
    scrollView.isHidden = !hasItems
    emptyStateView.isHidden = hasItems
    if !hasItems {
      emptyStateView.configure(
        symbolName: SidebarCategory.codes.symbolName,
        title: SidebarCategory.codes.emptyListTitle,
        message: SidebarCategory.codes.emptyListMessage
      )
    }
  }

  @objc
  private func addVerificationCode(_ sender: Any?) {
    guard let window = view.window else { return }
    AddVerificationCodeSheetController.present(dataSource: dataSource, from: window) { _ in
      // Nothing to do on either outcome: `itemsDidChange` (on a successful save) drives
      // `rebuildRows()` above the same way any other mutation does.
    }
  }

  private func item(at row: Int) -> PasswordItem? {
    guard rows.indices.contains(row), case .item(let item) = rows[row] else { return nil }
    return item
  }
}

extension CodesViewController: NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int {
    rows.count
  }
}

extension CodesViewController: NSTableViewDelegate {
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    switch rows[row] {
    case .section(let title):
      let cell = SectionHeaderCellView.dequeue(from: tableView, owner: self)
      cell.configure(title: title)
      return cell
    case .item(let item):
      let cell = CodeRowCellView.dequeue(from: tableView, owner: self)
      cell.configure(with: item, at: Date())
      return cell
    }
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    switch rows[row] {
    case .section: return 28
    case .item: return 52
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

  /// A "click to copy" gesture: selecting a code row copies its current code, flashes a "Copied"
  /// confirmation over that row, then deselects — so the row behaves like a momentary button
  /// rather than a persistent selection.
  func tableViewSelectionDidChange(_ notification: Notification) {
    let row = tableView.selectedRow
    guard row >= 0, let item = item(at: row), let totp = item.totp else { return }
    Pasteboard.copySecret(totp.code(at: Date()))
    if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? CodeRowCellView {
      cell.flashCopied(for: item.id)
    }
    tableView.deselectAll(nil)
  }
}
