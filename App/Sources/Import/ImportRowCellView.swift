import AppKit
import LilPasswordsKit

/// A single row of the import preview table: title/username, a status pill (New/Duplicate/
/// Conflict), and — only for a conflict — a popup to choose how it should be resolved.
final class ImportRowCellView: NSTableCellView {
  static let reuseIdentifier = NSUserInterfaceItemIdentifier("ImportRow")

  private let titleField = NSTextField(labelWithString: "")
  private let subtitleField = NSTextField(labelWithString: "")
  private let statusField = NSTextField(labelWithString: "")
  private let resolutionPopUp = NSPopUpButton(frame: .zero, pullsDown: false)

  /// Called when the user changes the conflict resolution popup, with the newly selected value.
  var onResolutionChange: ((ImportConflictResolution) -> Void)?

  static func dequeue(from tableView: NSTableView, owner: Any?) -> ImportRowCellView {
    if let existing = tableView.makeView(withIdentifier: reuseIdentifier, owner: owner) as? ImportRowCellView {
      return existing
    }
    return ImportRowCellView()
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
    titleField.translatesAutoresizingMaskIntoConstraints = false
    titleField.font = .systemFont(ofSize: 13)
    titleField.lineBreakMode = .byTruncatingTail

    subtitleField.translatesAutoresizingMaskIntoConstraints = false
    subtitleField.font = .systemFont(ofSize: 11)
    subtitleField.textColor = .secondaryLabelColor
    subtitleField.lineBreakMode = .byTruncatingTail

    statusField.translatesAutoresizingMaskIntoConstraints = false
    statusField.font = .systemFont(ofSize: 11, weight: .semibold)
    statusField.alignment = .right

    resolutionPopUp.translatesAutoresizingMaskIntoConstraints = false
    resolutionPopUp.controlSize = .small
    resolutionPopUp.font = .systemFont(ofSize: 11)
    for resolution in ImportConflictResolution.allCases {
      resolutionPopUp.addItem(withTitle: resolution.title)
    }
    resolutionPopUp.target = self
    resolutionPopUp.action = #selector(resolutionChanged)

    addSubview(titleField)
    addSubview(subtitleField)
    addSubview(statusField)
    addSubview(resolutionPopUp)

    NSLayoutConstraint.activate([
      titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      titleField.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      titleField.trailingAnchor.constraint(lessThanOrEqualTo: statusField.leadingAnchor, constant: -8),

      subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
      subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
      subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: statusField.leadingAnchor, constant: -8),

      statusField.centerYAnchor.constraint(equalTo: centerYAnchor),
      statusField.widthAnchor.constraint(equalToConstant: 70),

      resolutionPopUp.leadingAnchor.constraint(equalTo: statusField.trailingAnchor, constant: 8),
      resolutionPopUp.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      resolutionPopUp.centerYAnchor.constraint(equalTo: centerYAnchor),
      resolutionPopUp.widthAnchor.constraint(equalToConstant: 110),
    ])
  }

  func configure(with row: ImportPreviewRow) {
    titleField.stringValue = row.imported.title
    let subtitle = row.imported.username
    subtitleField.stringValue = subtitle
    subtitleField.isHidden = subtitle.isEmpty

    statusField.stringValue = row.statusText
    statusField.textColor = {
      switch row.decision {
      case .new: return .systemGreen
      case .duplicate: return .secondaryLabelColor
      case .conflict: return .systemOrange
      }
    }()

    resolutionPopUp.isHidden = !row.isConflict
    if row.isConflict, let index = ImportConflictResolution.allCases.firstIndex(of: row.resolution) {
      resolutionPopUp.selectItem(at: index)
    }
  }

  @objc private func resolutionChanged() {
    let index = resolutionPopUp.indexOfSelectedItem
    guard ImportConflictResolution.allCases.indices.contains(index) else { return }
    onResolutionChange?(ImportConflictResolution.allCases[index])
  }
}
