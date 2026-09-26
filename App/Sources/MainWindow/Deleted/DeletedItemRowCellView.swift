import AppKit
import LilPasswordsKit

/// A single row in the Deleted view (851-2420): icon, title, "N days" remaining before permanent
/// purge, and the two per-item actions Apple Passwords offers here — Recover and Delete
/// Permanently (the latter behind a confirmation, handled by ``DeletedViewController``, not this
/// cell).
final class DeletedItemRowCellView: NSTableCellView {
  static let reuseIdentifier = NSUserInterfaceItemIdentifier("DeletedItemRow")

  private let iconView = NSImageView()
  private let titleField = NSTextField(labelWithString: "")
  private let subtitleField = NSTextField(labelWithString: "")
  private let recoverButton = NSButton()
  private let deleteButton = NSButton()

  /// Set fresh on every `configure(...)` call — cells are reused across rows.
  var onRecoverTapped: (() -> Void)?
  var onDeletePermanentlyTapped: (() -> Void)?

  static func dequeue(from tableView: NSTableView, owner: Any?) -> DeletedItemRowCellView {
    if let existing = tableView.makeView(withIdentifier: reuseIdentifier, owner: owner) as? DeletedItemRowCellView {
      return existing
    }
    return DeletedItemRowCellView()
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

    recoverButton.translatesAutoresizingMaskIntoConstraints = false
    recoverButton.title = "Recover"
    recoverButton.bezelStyle = .rounded
    recoverButton.controlSize = .small
    recoverButton.target = self
    recoverButton.action = #selector(recoverTapped)

    deleteButton.translatesAutoresizingMaskIntoConstraints = false
    deleteButton.title = "Delete Permanently"
    deleteButton.bezelStyle = .rounded
    deleteButton.controlSize = .small
    deleteButton.contentTintColor = .systemRed
    deleteButton.target = self
    deleteButton.action = #selector(deleteTapped)

    addSubview(iconView)
    addSubview(titleField)
    addSubview(subtitleField)
    addSubview(deleteButton)
    addSubview(recoverButton)

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 28),
      iconView.heightAnchor.constraint(equalToConstant: 28),

      titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
      titleField.topAnchor.constraint(equalTo: topAnchor, constant: 6),

      subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
      subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),

      deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),

      recoverButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
      recoverButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      recoverButton.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 12),
    ])
  }

  func configure(with item: PasswordItem, now: Date) {
    iconView.image = MonogramIcon.icon(for: item.title)
    titleField.stringValue = item.title
    let days = item.daysRemaining(now: now) ?? 0
    subtitleField.stringValue = days == 1 ? "1 day" : "\(days) days"
  }

  @objc
  private func recoverTapped() {
    onRecoverTapped?()
  }

  @objc
  private func deleteTapped() {
    onDeletePermanentlyTapped?()
  }
}
