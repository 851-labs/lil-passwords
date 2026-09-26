import AppKit
import LilPasswordsKit

/// The detail pane shown beside the Deleted list (851-2426 review note: replace the heavy
/// per-row Recover/Delete Permanently buttons with a context menu plus a detail pane, matching
/// how Apple Passwords itself pairs a plain list with a detail column for actions). Shows the
/// selected item's icon, title, and days remaining before the daily purge erases it for good,
/// plus the two actions; an empty state covers "nothing selected" (including "nothing in
/// Recently Deleted at all", since that leaves the selection empty too).
///
/// The row's own right-click context menu (`DeletedViewController.contextMenu`) still offers the
/// same two actions for anyone who'd rather not move selection first — this pane doesn't replace
/// it, it replaces the buttons that used to live on every row.
@MainActor
final class DeletedDetailView: NSView {
  var onRecoverTapped: (() -> Void)?
  var onDeletePermanentlyTapped: (() -> Void)?

  private let emptyStateView = EmptyStateView()
  private let contentView = NSView()
  private let iconView = NSImageView()
  private let titleField = NSTextField(labelWithString: "")
  private let subtitleField = NSTextField(labelWithString: "")
  private let recoverButton = NSButton()
  private let deleteButton = NSButton()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureSubviews()
    showNoSelection()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func configureSubviews() {
    translatesAutoresizingMaskIntoConstraints = false

    emptyStateView.translatesAutoresizingMaskIntoConstraints = false
    emptyStateView.configure(
      symbolName: "trash",
      title: "No Item Selected",
      message: "Select an item to recover it or delete it permanently."
    )

    contentView.translatesAutoresizingMaskIntoConstraints = false

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.imageScaling = .scaleProportionallyUpOrDown

    titleField.font = .systemFont(ofSize: 20, weight: .semibold)
    titleField.alignment = .center
    titleField.lineBreakMode = .byTruncatingTail
    titleField.translatesAutoresizingMaskIntoConstraints = false

    subtitleField.font = .systemFont(ofSize: 13)
    subtitleField.alignment = .center
    subtitleField.textColor = .secondaryLabelColor
    subtitleField.translatesAutoresizingMaskIntoConstraints = false

    recoverButton.title = "Recover"
    recoverButton.bezelStyle = .rounded
    recoverButton.controlSize = .large
    // Recover is the safe, reversible action here, so it (not Delete Permanently) gets the
    // sheet/pane's default-button treatment — Return recovers the selection.
    recoverButton.keyEquivalent = "\r"
    recoverButton.target = self
    recoverButton.action = #selector(recoverTapped)
    recoverButton.setAccessibilityLabel("Recover")
    recoverButton.translatesAutoresizingMaskIntoConstraints = false

    deleteButton.title = "Delete Permanently…"
    deleteButton.bezelStyle = .rounded
    deleteButton.controlSize = .large
    deleteButton.contentTintColor = .systemRed
    deleteButton.target = self
    deleteButton.action = #selector(deleteTapped)
    deleteButton.setAccessibilityLabel("Delete Permanently")
    deleteButton.translatesAutoresizingMaskIntoConstraints = false

    let buttonStack = NSStackView(views: [recoverButton, deleteButton])
    buttonStack.orientation = .horizontal
    buttonStack.spacing = 12
    buttonStack.translatesAutoresizingMaskIntoConstraints = false

    contentView.addSubview(iconView)
    contentView.addSubview(titleField)
    contentView.addSubview(subtitleField)
    contentView.addSubview(buttonStack)

    addSubview(emptyStateView)
    addSubview(contentView)

    NSLayoutConstraint.activate([
      emptyStateView.leadingAnchor.constraint(equalTo: leadingAnchor),
      emptyStateView.trailingAnchor.constraint(equalTo: trailingAnchor),
      emptyStateView.topAnchor.constraint(equalTo: topAnchor),
      emptyStateView.bottomAnchor.constraint(equalTo: bottomAnchor),

      contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
      contentView.topAnchor.constraint(equalTo: topAnchor),
      contentView.bottomAnchor.constraint(equalTo: bottomAnchor),

      iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -60),
      iconView.widthAnchor.constraint(equalToConstant: 64),
      iconView.heightAnchor.constraint(equalToConstant: 64),

      titleField.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 14),
      titleField.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      titleField.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 24),
      titleField.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),

      subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 4),
      subtitleField.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      subtitleField.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 24),
      subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),

      buttonStack.topAnchor.constraint(equalTo: subtitleField.bottomAnchor, constant: 24),
      buttonStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
    ])
  }

  /// Nothing selected — either by choice, or because Recently Deleted is empty (the list's own
  /// `EmptyStateView`, not this one, explains that case on the list side).
  func showNoSelection() {
    contentView.isHidden = true
    emptyStateView.isHidden = false
    setAccessibilityLabel(nil)
  }

  /// A single selected item: its icon/title, days remaining, and the two actions.
  func show(item: PasswordItem, now: Date) {
    emptyStateView.isHidden = true
    contentView.isHidden = false
    iconView.image = MonogramIcon.icon(for: item.title)
    subtitleField.isHidden = false
    titleField.stringValue = item.title
    let days = item.daysRemaining(now: now) ?? 0
    let remaining =
      days <= 0
      ? "Will be deleted permanently today"
      : days == 1
        ? "1 day remaining before permanent deletion"
        : "\(days) days remaining before permanent deletion"
    subtitleField.stringValue = remaining
    recoverButton.title = "Recover"
    deleteButton.title = "Delete Permanently…"
    setAccessibilityLabel("\(item.title), \(remaining)")
  }

  /// A multi-item selection: just the count plus bulk actions over the whole selection.
  func showMultipleSelection(count: Int) {
    emptyStateView.isHidden = true
    contentView.isHidden = false
    iconView.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
    titleField.stringValue = "\(count) Items Selected"
    subtitleField.isHidden = true
    recoverButton.title = "Recover All"
    deleteButton.title = "Delete Permanently…"
    setAccessibilityLabel("\(count) items selected")
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
