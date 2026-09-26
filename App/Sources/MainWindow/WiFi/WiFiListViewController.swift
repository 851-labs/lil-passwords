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
@MainActor
final class WiFiListViewController: NSViewController {
  weak var delegate: WiFiListViewControllerDelegate?

  private let viewModel: WiFiNetworkViewModel
  private var cancellable: AnyCancellable?
  private var networks: [WiFiNetwork] = []

  private let headerBar = NSView()
  private let countLabel = NSTextField(labelWithString: "")
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

    cancellable = viewModel.$networks
      .receive(on: RunLoop.main)
      .sink { [weak self] networks in self?.applyNetworks(networks) }
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    Task { await viewModel.refresh() }
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
    tableView.style = .plain
    tableView.intercellSpacing = NSSize(width: 0, height: 0)
    tableView.rowHeight = 48
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

  private func applyNetworks(_ networks: [WiFiNetwork]) {
    let previouslySelectedSSID = selectedNetwork()?.ssid
    self.networks = networks
    tableView.reloadData()

    let count = networks.count
    countLabel.stringValue = count == 1 ? String(localized: "1 Network") : String(localized: "\(count) Networks")

    let hasNetworks = !networks.isEmpty
    scrollView.isHidden = !hasNetworks
    emptyStateView.isHidden = hasNetworks
    if !hasNetworks {
      emptyStateView.configure(
        symbolName: SidebarCategory.wifi.symbolName,
        title: SidebarCategory.wifi.emptyListTitle,
        message: SidebarCategory.wifi.emptyListMessage
      )
    }

    if let previouslySelectedSSID, let row = networks.firstIndex(where: { $0.ssid == previouslySelectedSSID }) {
      tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    } else {
      delegate?.wifiListViewController(self, didSelect: nil)
    }
  }

  private func selectedNetwork() -> WiFiNetwork? {
    guard tableView.selectedRow >= 0, tableView.selectedRow < networks.count else { return nil }
    return networks[tableView.selectedRow]
  }
}

extension WiFiListViewController: NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int {
    networks.count
  }
}

extension WiFiListViewController: NSTableViewDelegate {
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let cell = WiFiNetworkRowCellView.dequeue(from: tableView, owner: self)
    cell.configure(with: networks[row])
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    delegate?.wifiListViewController(self, didSelect: selectedNetwork())
  }
}
