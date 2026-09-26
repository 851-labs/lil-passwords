import AppKit
import LilPasswordsKit

/// A single item row in the item list: monogram icon, title, and username as secondary text —
/// the Apple Passwords item-row layout (851-2414).
final class ItemRowCellView: NSTableCellView {
  static let reuseIdentifier = NSUserInterfaceItemIdentifier("ItemRow")

  private let iconView = NSImageView()
  private let titleField = NSTextField(labelWithString: "")
  private let subtitleField = NSTextField(labelWithString: "")

  static func dequeue(from tableView: NSTableView, owner: Any?) -> ItemRowCellView {
    if let existing = tableView.makeView(withIdentifier: reuseIdentifier, owner: owner) as? ItemRowCellView {
      return existing
    }
    return ItemRowCellView()
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

    subtitleField.translatesAutoresizingMaskIntoConstraints = false
    subtitleField.font = .systemFont(ofSize: 11)
    subtitleField.textColor = .secondaryLabelColor
    subtitleField.lineBreakMode = .byTruncatingTail

    addSubview(iconView)
    addSubview(titleField)
    addSubview(subtitleField)

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 28),
      iconView.heightAnchor.constraint(equalToConstant: 28),

      titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
      titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
      titleField.topAnchor.constraint(equalTo: topAnchor, constant: 6),

      subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
      subtitleField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
      subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
    ])
  }

  func configure(with item: PasswordItem) {
    iconView.image = MonogramIcon.icon(for: item.title)
    titleField.stringValue = item.title
    let subtitle = item.usernames.first(where: { !$0.isEmpty })
    subtitleField.stringValue = subtitle ?? ""
    subtitleField.isHidden = subtitle == nil
  }
}

/// An alphabetical section header row ("A", "B", "#", ...) shown above each letter group when
/// the list is sorted by title, matching Contacts/Apple Passwords.
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
