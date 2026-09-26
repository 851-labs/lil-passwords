import AppKit

/// The large icon + title + "Last modified" header at the top of the detail pane, matching
/// Apple Passwords. The title becomes an editable text field in edit mode.
///
/// Also hosts the Edit/Cancel/Done cluster, top-right — matching where Apple Passwords puts
/// Edit — rather than a separate row drawn at the very top of the content area. The detail
/// pane's own view starts underneath the window's real unified toolbar, but a manually-drawn
/// row pinned to the top of that view sits close enough to the toolbar's translucent background
/// to visibly show through it; anchoring the buttons to the header (which already sits well
/// clear of the toolbar) avoids that overlap entirely.
@MainActor
final class DetailHeaderView: NSView {
  var onTitleChange: ((String) -> Void)?
  var onEditTapped: (() -> Void)?
  var onCancelTapped: (() -> Void)?
  var onDoneTapped: (() -> Void)?

  private let iconView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let titleField = NSTextField()
  private let subtitleLabel = NSTextField(labelWithString: "")

  private let editButton = NSButton(title: "Edit", target: nil, action: nil)
  private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  private let doneButton = NSButton(title: "Done", target: nil, action: nil)

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureSubviews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func configureSubviews() {
    translatesAutoresizingMaskIntoConstraints = false

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.imageScaling = .scaleProportionallyUpOrDown

    titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    titleField.font = .systemFont(ofSize: 22, weight: .semibold)
    titleField.isBordered = true
    titleField.isBezeled = true
    titleField.bezelStyle = .roundedBezel
    titleField.isHidden = true
    titleField.target = self
    titleField.action = #selector(titleFieldChanged)
    titleField.delegate = self
    titleField.translatesAutoresizingMaskIntoConstraints = false

    subtitleLabel.font = .systemFont(ofSize: 12)
    subtitleLabel.textColor = .secondaryLabelColor
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

    let textStack = NSStackView(views: [titleLabel, titleField, subtitleLabel])
    textStack.orientation = .vertical
    textStack.alignment = .leading
    textStack.spacing = 4
    textStack.translatesAutoresizingMaskIntoConstraints = false

    editButton.bezelStyle = .rounded
    editButton.target = self
    editButton.action = #selector(editTapped)

    cancelButton.bezelStyle = .rounded
    cancelButton.target = self
    cancelButton.action = #selector(cancelTapped)
    cancelButton.keyEquivalent = "\u{1b}"  // Escape
    cancelButton.isHidden = true

    doneButton.bezelStyle = .rounded
    doneButton.keyEquivalent = "\r"
    doneButton.target = self
    doneButton.action = #selector(doneTapped)
    doneButton.isHidden = true

    let buttonStack = NSStackView(views: [cancelButton, doneButton, editButton])
    buttonStack.orientation = .horizontal
    buttonStack.spacing = 8
    buttonStack.translatesAutoresizingMaskIntoConstraints = false

    addSubview(iconView)
    addSubview(textStack)
    addSubview(buttonStack)

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
      iconView.topAnchor.constraint(equalTo: topAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 64),
      iconView.heightAnchor.constraint(equalToConstant: 64),

      textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 16),
      textStack.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -12),
      textStack.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

      titleField.widthAnchor.constraint(equalToConstant: 260),

      buttonStack.trailingAnchor.constraint(equalTo: trailingAnchor),
      buttonStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),

      bottomAnchor.constraint(equalTo: iconView.bottomAnchor),
    ])
  }

  /// - Parameters:
  ///   - title: The item's display title.
  ///   - icon: The large rounded-square icon (see `ItemIconFactory`).
  ///   - modifiedAt: When the item was last changed, rendered as "Last modified <date>".
  ///   - isEditing: Whether the title should be shown as an editable field, and Cancel/Done
  ///     shown in place of Edit.
  func configure(title: String, icon: NSImage, modifiedAt: Date, isEditing: Bool) {
    iconView.image = icon
    titleLabel.stringValue = title
    if titleField.stringValue != title {
      titleField.stringValue = title
    }
    subtitleLabel.stringValue = "Last modified \(Self.dateFormatter.string(from: modifiedAt))"

    titleLabel.isHidden = isEditing
    titleField.isHidden = !isEditing

    editButton.isHidden = isEditing
    cancelButton.isHidden = !isEditing
    doneButton.isHidden = !isEditing
  }

  @objc
  private func titleFieldChanged() {
    onTitleChange?(titleField.stringValue)
  }

  @objc
  private func editTapped() {
    onEditTapped?()
  }

  @objc
  private func cancelTapped() {
    onCancelTapped?()
  }

  @objc
  private func doneTapped() {
    onDoneTapped?()
  }
}

extension DetailHeaderView: NSTextFieldDelegate {
  func controlTextDidChange(_ notification: Notification) {
    onTitleChange?(titleField.stringValue)
  }
}
