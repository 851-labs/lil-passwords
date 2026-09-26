import AppKit
import LilPasswordsKit

/// Shows the result of running ``ImportMergePlanner`` against the file the user picked: a summary
/// of how many rows are New / Duplicate (skipped) / Conflict, and a table where each conflicting
/// row gets a per-row resolution choice (Keep Existing / Replace / Keep Both). Duplicates are
/// listed too, so the user can see what's being skipped and why, but have no choice to make.
@MainActor
final class ImportPreviewViewController: NSViewController {
  private var rows: [ImportPreviewRow]
  private let summaryField = NSTextField(labelWithString: "")
  private let tableView = NSTableView()
  private let scrollView = NSScrollView()
  private let importButton = NSButton()

  var onCancel: (() -> Void)?
  var onImport: (([ImportPreviewRow]) -> Void)?

  init(plan: ImportPlan) {
    self.rows = .rows(for: plan)
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 420))
    configureSubviews()
  }

  private func configureSubviews() {
    summaryField.translatesAutoresizingMaskIntoConstraints = false
    summaryField.font = .systemFont(ofSize: 12)
    summaryField.textColor = .secondaryLabelColor
    summaryField.stringValue = summaryText()

    let titleField = NSTextField(labelWithString: String(localized: "Import Passwords"))
    titleField.translatesAutoresizingMaskIntoConstraints = false
    titleField.font = .systemFont(ofSize: 16, weight: .semibold)

    tableView.headerView = nil
    tableView.rowSizeStyle = .custom
    tableView.rowHeight = 44
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.dataSource = self
    tableView.delegate = self
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Row"))
    column.width = 480
    tableView.addTableColumn(column)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .bezelBorder

    let cancelButton = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelTapped))
    cancelButton.translatesAutoresizingMaskIntoConstraints = false
    cancelButton.bezelStyle = .rounded
    cancelButton.keyEquivalent = "\u{1b}"

    importButton.translatesAutoresizingMaskIntoConstraints = false
    importButton.title = String(localized: "Import")
    importButton.bezelStyle = .rounded
    importButton.keyEquivalent = "\r"
    // `keyEquivalent = "\r"` alone doesn't reliably paint this blue for a plain NSButton hosted
    // in a custom sheet the way it does for NSAlert's own default button — review note (851-2426):
    // "make Import the default (blue) button." `bezelColor` is the explicit, focus-independent way
    // to opt a push button into that "prominent/default" tint.
    importButton.bezelColor = .controlAccentColor
    importButton.target = self
    importButton.action = #selector(importTapped)
    importButton.isEnabled = !rows.isEmpty

    let buttonRow = NSStackView(views: [cancelButton, NSView(), importButton])
    buttonRow.translatesAutoresizingMaskIntoConstraints = false
    buttonRow.orientation = .horizontal
    buttonRow.distribution = .fill

    view.addSubview(titleField)
    view.addSubview(summaryField)
    view.addSubview(scrollView)
    view.addSubview(buttonRow)

    NSLayoutConstraint.activate([
      titleField.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
      titleField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

      summaryField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 6),
      summaryField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      summaryField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

      scrollView.topAnchor.constraint(equalTo: summaryField.bottomAnchor, constant: 12),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      scrollView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -16),

      buttonRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      buttonRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      buttonRow.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
    ])
  }

  private func summaryText() -> String {
    String(
      localized: """
        \(rows.newCount) new · \(rows.duplicateCount) duplicate (skipped) · \
        \(rows.conflictCount) conflict\(rows.conflictCount == 1 ? "" : "s")
        """
    )
  }

  @objc private func cancelTapped() {
    onCancel?()
  }

  @objc private func importTapped() {
    onImport?(rows)
  }
}

extension ImportPreviewViewController: NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
}

extension ImportPreviewViewController: NSTableViewDelegate {
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let cell = ImportRowCellView.dequeue(from: tableView, owner: self)
    cell.configure(with: rows[row])
    cell.onResolutionChange = { [weak self] resolution in
      self?.rows[row].resolution = resolution
    }
    return cell
  }
}
