import AppKit
import LilPasswordsKit

/// Settings → Agents: the access toggle (851-2428) and access log (851-2429), both still
/// backlog — this tab only stores the toggle's preference and shows a placeholder log. The
/// helper doesn't enforce the toggle yet, and nothing writes log entries yet.
@MainActor
final class AgentsSettingsViewController: NSViewController {
  private enum Column {
    static let time = NSUserInterfaceItemIdentifier("Time")
    static let item = NSUserInterfaceItemIdentifier("Item")
    static let fields = NSUserInterfaceItemIdentifier("Fields")
  }

  private let settings: AppSettings

  private let allowCheckbox = NSButton(
    checkboxWithTitle: "Allow agents to access passwords",
    target: nil,
    action: nil
  )
  private let keepUnlockedCheckbox = NSButton(
    checkboxWithTitle: "Keep agent access available while the Mac is unlocked",
    target: nil,
    action: nil
  )
  private let clearLogButton = NSButton(title: "Clear Log", target: nil, action: nil)
  private let emptyLogLabel = NSTextField(labelWithString: "No agent activity yet.")
  private let logTableView = NSTableView()

  init(settings: AppSettings = .shared) {
    self.settings = settings
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func loadView() {
    allowCheckbox.target = self
    allowCheckbox.action = #selector(allowToggled(_:))

    keepUnlockedCheckbox.target = self
    keepUnlockedCheckbox.action = #selector(keepUnlockedToggled(_:))

    clearLogButton.bezelStyle = .rounded
    // There's nothing to clear until 851-2429 actually records entries.
    clearLogButton.isEnabled = false

    emptyLogLabel.font = .systemFont(ofSize: 11)
    emptyLogLabel.textColor = .tertiaryLabelColor
    emptyLogLabel.alignment = .center

    view = SettingsLayout.makeStack([
      allowCheckbox,
      SettingsLayout.caption(
        "The \(LilPasswordsKit.cliName) CLI and MCP server can read every password with no prompts while "
          + "\(LilPasswordsKit.productName) is unlocked. Turning this off, or locking the vault, blocks access."
      ),
      keepUnlockedCheckbox,
      SettingsLayout.caption("Otherwise, agent access follows \(LilPasswordsKit.productName)'s own auto-lock."),
      SettingsLayout.sectionHeader("Access Log"),
      makeLogSection(),
      clearLogButton,
      SettingsLayout.caption(
        "Every agent request will be recorded here — time, tool, item, and fields accessed, never secret values."),
    ])
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    preferredContentSize = SettingsLayout.preferredSize(for: view)
    loadFromSettings()
  }

  private func loadFromSettings() {
    allowCheckbox.state = settings.agentAccessEnabled ? .on : .off
    keepUnlockedCheckbox.state = settings.keepAgentAccessAvailableWhileMacUnlocked ? .on : .off
  }

  private func makeLogSection() -> NSView {
    logTableView.dataSource = self
    logTableView.delegate = self
    logTableView.usesAlternatingRowBackgroundColors = true
    logTableView.headerView = NSTableHeaderView()

    let timeColumn = NSTableColumn(identifier: Column.time)
    timeColumn.title = "Time"
    timeColumn.width = 120
    logTableView.addTableColumn(timeColumn)

    let itemColumn = NSTableColumn(identifier: Column.item)
    itemColumn.title = "Item"
    itemColumn.width = 160
    logTableView.addTableColumn(itemColumn)

    let fieldsColumn = NSTableColumn(identifier: Column.fields)
    fieldsColumn.title = "Fields"
    fieldsColumn.width = 100
    logTableView.addTableColumn(fieldsColumn)

    let scrollView = NSScrollView()
    scrollView.documentView = logTableView
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .bezelBorder
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false
    emptyLogLabel.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(scrollView)
    container.addSubview(emptyLogLabel)

    NSLayoutConstraint.activate([
      container.widthAnchor.constraint(equalToConstant: SettingsLayout.contentWidth - 40),
      container.heightAnchor.constraint(equalToConstant: 120),
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: container.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      emptyLogLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      emptyLogLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])

    return container
  }

  @objc private func allowToggled(_ sender: NSButton) {
    settings.agentAccessEnabled = sender.state == .on
  }

  @objc private func keepUnlockedToggled(_ sender: NSButton) {
    settings.keepAgentAccessAvailableWhileMacUnlocked = sender.state == .on
  }
}

extension AgentsSettingsViewController: NSTableViewDataSource, NSTableViewDelegate {
  // Always empty until 851-2429 records real access-log entries.
  func numberOfRows(in tableView: NSTableView) -> Int { 0 }
}
