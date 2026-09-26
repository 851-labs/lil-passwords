import AppKit
import Combine

@MainActor
protocol SidebarViewControllerDelegate: AnyObject {
  func sidebarViewController(_ controller: SidebarViewController, didSelect category: SidebarCategory)
}

/// The source-list sidebar: All, Passkeys, Codes, Wi-Fi, Security, Deleted, plus a hidden
/// "Shared Groups" section that appears once `VaultSnapshot.sharedGroups` is non-empty.
///
/// Row content (titles, symbols, counts) all comes from `SidebarCategory` and `VaultSnapshot`,
/// not from a concrete item model, since `PasswordItem` (851-2403) doesn't exist yet.
@MainActor
final class SidebarViewController: NSViewController {
  private enum Node: Hashable {
    case category(SidebarCategory)
    case sharedGroupsHeader
    case sharedGroup(VaultSnapshot.SharedGroup)
  }

  private enum Column {
    static let identifier = NSUserInterfaceItemIdentifier("Sidebar")
  }

  private static let restorationCategoryKey = "SidebarViewController.selectedCategory"

  weak var delegate: SidebarViewControllerDelegate?

  private let store: VaultSnapshotStore
  private var cancellable: AnyCancellable?

  private var topLevelNodes: [Node] = SidebarCategory.allCases.map(Node.category)
  private(set) var selectedCategory: SidebarCategory = .all

  private let outlineView = NSOutlineView()
  private let scrollView = NSScrollView()

  init(store: VaultSnapshotStore) {
    self.store = store
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func loadView() {
    // `NSSplitViewItem(sidebarWithViewController:)` marks this column as a sidebar, but it
    // doesn't paint the vibrant/glass material itself — without an actual `NSVisualEffectView`
    // behind the outline view, the column just shows through to the plain window background,
    // which is what made it read as flat and indistinguishable from the content column. This is
    // the system "sidebar" material: vibrant on macOS 13-15, floating glass on macOS 26.
    let effectView = NSVisualEffectView()
    effectView.material = .sidebar
    effectView.blendingMode = .behindWindow
    effectView.state = .followsWindowActiveState
    view = effectView
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    configureOutlineView()
    configureScrollView()

    cancellable = store.$snapshot
      .receive(on: RunLoop.main)
      .sink { [weak self] snapshot in
        self?.apply(snapshot)
      }

    outlineView.expandItem(nil, expandChildren: true)
    selectRow(for: .all)
  }

  private func configureOutlineView() {
    outlineView.headerView = nil
    outlineView.floatsGroupRows = false
    outlineView.style = .sourceList
    outlineView.rowSizeStyle = .default
    outlineView.indentationPerLevel = 0
    outlineView.dataSource = self
    outlineView.delegate = self
    outlineView.autosaveExpandedItems = false
    // Let the sidebar material (set up in loadView) show through instead of painting the
    // opaque `.controlBackgroundColor` the outline view uses by default.
    outlineView.backgroundColor = .clear

    let column = NSTableColumn(identifier: Column.identifier)
    column.title = String(localized: "Sidebar")
    outlineView.addTableColumn(column)
    outlineView.outlineTableColumn = column
  }

  private func configureScrollView() {
    scrollView.documentView = outlineView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    view.addSubview(scrollView)
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func apply(_ snapshot: VaultSnapshot) {
    topLevelNodes = SidebarCategory.allCases.map(Node.category)
    if !snapshot.sharedGroups.isEmpty {
      topLevelNodes.append(.sharedGroupsHeader)
    }
    outlineView.reloadData()
    outlineView.expandItem(nil, expandChildren: true)
    selectRow(for: selectedCategory)
  }

  private func selectRow(for category: SidebarCategory) {
    let row = outlineView.row(forItem: Node.category(category))
    guard row >= 0 else { return }
    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
  }

  /// Programmatically selects `category`, exactly as if the user had clicked its row — unlike a
  /// real click, this notifies the delegate unconditionally, even if the outline view hasn't laid
  /// out rows yet (see `restoreState(with:)` above for the same pattern). Used by the DEBUG-only
  /// `-InitialSidebarCategory` launch argument (`MainWindowController`) so tophat/manual-QA
  /// captures of the full-width Codes/Security/Deleted views don't depend on a live click.
  func selectCategory(_ category: SidebarCategory) {
    selectedCategory = category
    selectRow(for: category)
    invalidateRestorableState()
    delegate?.sidebarViewController(self, didSelect: category)
  }

  // MARK: State restoration

  override func encodeRestorableState(with coder: NSCoder) {
    super.encodeRestorableState(with: coder)
    coder.encode(selectedCategory.rawValue, forKey: Self.restorationCategoryKey)
  }

  override func restoreState(with coder: NSCoder) {
    super.restoreState(with: coder)
    if let rawValue = coder.decodeObject(forKey: Self.restorationCategoryKey) as? String,
      let category = SidebarCategory(rawValue: rawValue)
    {
      selectedCategory = category
      selectRow(for: category)
      delegate?.sidebarViewController(self, didSelect: category)
    }
  }

  private func children(of node: Node?) -> [Node] {
    guard let node else { return topLevelNodes }
    switch node {
    case .sharedGroupsHeader:
      return store.snapshot.sharedGroups.map(Node.sharedGroup)
    case .category, .sharedGroup:
      return []
    }
  }
}

extension SidebarViewController: NSOutlineViewDataSource {
  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    children(of: item as? Node).count
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    children(of: item as? Node)[index]
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    (item as? Node) == .sharedGroupsHeader
  }
}

extension SidebarViewController: NSOutlineViewDelegate {
  func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
    (item as? Node) == .sharedGroupsHeader
  }

  func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
    (item as? Node) != .sharedGroupsHeader
  }

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    guard let node = item as? Node else { return nil }

    switch node {
    case .sharedGroupsHeader:
      return makeGroupRowView(title: String(localized: "Shared Groups"))
    case .category(let category):
      return makeCategoryRowView(category: category)
    case .sharedGroup(let group):
      return makeSharedGroupRowView(group: group)
    }
  }

  func outlineViewSelectionDidChange(_ notification: Notification) {
    let row = outlineView.selectedRow
    guard row >= 0, let category = outlineView.item(atRow: row) as? Node, case .category(let value) = category
    else { return }
    selectedCategory = value
    invalidateRestorableState()
    delegate?.sidebarViewController(self, didSelect: value)
  }

  private func makeGroupRowView(title: String) -> NSView {
    let identifier = NSUserInterfaceItemIdentifier("GroupRow")
    let textField: NSTextField
    if let existing = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
      textField = existing
    } else {
      textField = NSTextField(labelWithString: "")
      textField.identifier = identifier
      textField.font = .systemFont(ofSize: 11, weight: .semibold)
      textField.textColor = .secondaryLabelColor
    }
    textField.stringValue = title.uppercased()
    return textField
  }

  private func makeCategoryRowView(category: SidebarCategory) -> NSView {
    let row = SidebarRowView.dequeue(from: outlineView, owner: self)
    let count = store.snapshot.count(for: category)
    row.configure(
      icon: SidebarIconFactory.icon(symbolName: category.symbolName, tint: category.tintColor),
      title: category.title,
      count: count
    )
    return row
  }

  private func makeSharedGroupRowView(group: VaultSnapshot.SharedGroup) -> NSView {
    let row = SidebarRowView.dequeue(from: outlineView, owner: self)
    row.configure(
      icon: SidebarIconFactory.icon(symbolName: "person.2.fill", tint: .systemIndigo),
      title: group.name,
      count: group.itemCount
    )
    return row
  }
}

/// A simple icon + title + trailing count row, reused for both categories and shared groups.
private final class SidebarRowView: NSTableCellView {
  private static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarRow")

  private let iconView = NSImageView()
  private let titleField = NSTextField(labelWithString: "")
  private let countField = NSTextField(labelWithString: "")

  static func dequeue(from outlineView: NSOutlineView, owner: Any?) -> SidebarRowView {
    if let existing = outlineView.makeView(withIdentifier: reuseIdentifier, owner: owner) as? SidebarRowView {
      return existing
    }
    return SidebarRowView()
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    identifier = Self.reuseIdentifier
    configureSubviews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func configureSubviews() {
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.imageScaling = .scaleProportionallyUpOrDown

    titleField.translatesAutoresizingMaskIntoConstraints = false
    titleField.font = .systemFont(ofSize: 13)
    titleField.lineBreakMode = .byTruncatingTail

    countField.translatesAutoresizingMaskIntoConstraints = false
    countField.font = .systemFont(ofSize: 12)
    countField.textColor = .tertiaryLabelColor
    countField.alignment = .right

    addSubview(iconView)
    addSubview(titleField)
    addSubview(countField)

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 18),
      iconView.heightAnchor.constraint(equalToConstant: 18),

      titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
      titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

      countField.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 4),
      countField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      countField.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  func configure(icon: NSImage, title: String, count: Int) {
    iconView.image = icon
    titleField.stringValue = title
    countField.stringValue = count > 0 ? "\(count)" : ""

    // A meaningful VoiceOver description for the whole row (851-2426), e.g. "All, 12 items" —
    // otherwise VoiceOver would read the icon, title, and count as three separate elements.
    setAccessibilityElement(true)
    setAccessibilityLabel(
      String(localized: "\(title), \(count == 1 ? String(localized: "1 item") : String(localized: "\(count) items"))"))
  }
}
