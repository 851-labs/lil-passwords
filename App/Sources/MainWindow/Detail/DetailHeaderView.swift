import AppKit

/// The large icon + title + "Last modified" header at the top of the detail pane, matching
/// Apple Passwords. The title becomes an editable text field in edit mode.
@MainActor
final class DetailHeaderView: NSView {
  var onTitleChange: ((String) -> Void)?

  private let iconView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let titleField = NSTextField()
  private let subtitleLabel = NSTextField(labelWithString: "")

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

    addSubview(iconView)
    addSubview(textStack)

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
      iconView.topAnchor.constraint(equalTo: topAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 64),
      iconView.heightAnchor.constraint(equalToConstant: 64),

      textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 16),
      textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      textStack.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

      titleField.widthAnchor.constraint(equalToConstant: 260),

      bottomAnchor.constraint(equalTo: iconView.bottomAnchor),
    ])
  }

  /// - Parameters:
  ///   - title: The item's display title.
  ///   - icon: The large rounded-square icon (see `ItemIconFactory`).
  ///   - modifiedAt: When the item was last changed, rendered as "Last modified <date>".
  ///   - isEditing: Whether the title should be shown as an editable field.
  func configure(title: String, icon: NSImage, modifiedAt: Date, isEditing: Bool) {
    iconView.image = icon
    titleLabel.stringValue = title
    if titleField.stringValue != title {
      titleField.stringValue = title
    }
    subtitleLabel.stringValue = "Last modified \(Self.dateFormatter.string(from: modifiedAt))"

    titleLabel.isHidden = isEditing
    titleField.isHidden = !isEditing
  }

  @objc
  private func titleFieldChanged() {
    onTitleChange?(titleField.stringValue)
  }
}

extension DetailHeaderView: NSTextFieldDelegate {
  func controlTextDidChange(_ notification: Notification) {
    onTitleChange?(titleField.stringValue)
  }
}
