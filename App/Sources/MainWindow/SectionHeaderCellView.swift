import AppKit

/// A small labeled section-header row for grouped table views — e.g. "Reused"/"Weak" groups in
/// `SecurityViewController`.
///
/// Originally lived in `ItemRowView.swift` as the item list's alphabetical ("A", "B", "#", ...)
/// section headers; 851-2463 made the item list one continuous, ungrouped list (matching Apple
/// Passwords), so it moved here as a standalone, reusable cell — `SecurityViewController`
/// (851-2419) still needs it to group findings by issue.
final class SectionHeaderCellView: NSTableCellView {
  static let reuseIdentifier = NSUserInterfaceItemIdentifier("SectionHeader")

  private let titleField = NSTextField(labelWithString: "")

  static func dequeue(from tableView: NSTableView, owner: Any?) -> SectionHeaderCellView {
    if let existing = tableView.makeView(withIdentifier: reuseIdentifier, owner: owner) as? SectionHeaderCellView {
      return existing
    }
    return SectionHeaderCellView()
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
    titleField.font = .systemFont(ofSize: 11, weight: .semibold)
    titleField.textColor = .secondaryLabelColor

    addSubview(titleField)
    NSLayoutConstraint.activate([
      titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  func configure(title: String) {
    titleField.stringValue = title
  }
}
