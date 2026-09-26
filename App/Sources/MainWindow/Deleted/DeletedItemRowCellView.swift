import AppKit
import LilPasswordsKit

/// A single row in the Deleted view (851-2420): icon, title, and "N days" remaining before
/// permanent purge. Just those three things — no per-row action buttons.
///
/// Earlier this row carried its own Recover/Delete Permanently buttons (matching Apple Passwords'
/// heavier row style in the very first pass), but 851-2426's review note asked for those to
/// become a right-click context menu (see `DeletedViewController.contextMenu`) plus a detail pane
/// (`DeletedDetailView`) instead, the way Apple's own Deleted-equivalent screens actually look —
/// so this cell went back to being a plain row.
final class DeletedItemRowCellView: NSTableCellView {
  static let reuseIdentifier = NSUserInterfaceItemIdentifier("DeletedItemRow")

  private let iconView = NSImageView()
  private let titleField = NSTextField(labelWithString: "")
  private let subtitleField = NSTextField(labelWithString: "")

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

    let textStack = NSStackView(views: [titleField, subtitleField])
    textStack.orientation = .vertical
    textStack.alignment = .leading
    textStack.spacing = 2
    textStack.translatesAutoresizingMaskIntoConstraints = false

    addSubview(iconView)
    addSubview(textStack)

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 28),
      iconView.heightAnchor.constraint(equalToConstant: 28),

      textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
      textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
      textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  func configure(with item: PasswordItem, now: Date) {
    iconView.image = MonogramIcon.icon(for: item.title)
    titleField.stringValue = item.title
    let days = item.daysRemaining(now: now) ?? 0
    let remaining = days == 1 ? "1 day" : "\(days) days"
    subtitleField.stringValue = remaining

    // A meaningful VoiceOver description for the whole row (851-2426), not just its title —
    // matching the "Amazon, jordan@…, has verification code" shape the ticket calls out.
    setAccessibilityElement(true)
    setAccessibilityLabel("\(item.title), \(remaining) remaining before permanent deletion")
  }
}
