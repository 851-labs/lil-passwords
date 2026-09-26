import AppKit

/// The centered icon + bold title at the top of the detail pane's primary card, matching Apple
/// Passwords (851-2463). The title becomes an editable, still-centered text field in edit mode.
///
/// Before 851-2463 this was a separate leading-aligned header drawn above the cards, and also
/// hosted the Edit/Cancel/Done button cluster. That cluster now lives in the toolbar
/// (`DetailEditToolbarView`, over the detail column), and this view is passed as the `header` of
/// `DetailViewController`'s primary `CardView` — the "Last modified" subtitle that used to sit
/// under the title is gone too, replaced by the card's own "Created" row.
@MainActor
final class DetailIdentityView: NSView {
  var onTitleChange: ((String) -> Void)?

  private let iconView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let titleField = NSTextField()

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

    titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
    titleLabel.alignment = .center
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    titleField.font = .systemFont(ofSize: 20, weight: .semibold)
    titleField.alignment = .center
    titleField.isBordered = true
    titleField.isBezeled = true
    titleField.bezelStyle = .roundedBezel
    titleField.isHidden = true
    titleField.target = self
    titleField.action = #selector(titleFieldChanged)
    titleField.delegate = self
    titleField.translatesAutoresizingMaskIntoConstraints = false

    addSubview(iconView)
    addSubview(titleLabel)
    addSubview(titleField)

    NSLayoutConstraint.activate([
      iconView.topAnchor.constraint(equalTo: topAnchor, constant: 28),
      iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 64),
      iconView.heightAnchor.constraint(equalToConstant: 64),

      titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),
      titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
      // 16pt, not the 24pt this shipped with: with the divider immediately below now actually
      // spanning full-width (see `DetailSectionContainerView.setRows`'s fix), 24pt read as a
      // noticeably bigger gap under the header than between any other two rows (851-2463 review:
      // "tighten the gap between the header and the rows").
      titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),

      titleField.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),
      titleField.centerXAnchor.constraint(equalTo: centerXAnchor),
      titleField.widthAnchor.constraint(equalToConstant: 240),
      titleField.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
    ])
  }

  /// - Parameters:
  ///   - title: The item's display title.
  ///   - icon: The large centered icon (see `MonogramIcon`).
  ///   - isEditing: Whether the title should be shown as an editable, centered text field.
  func configure(title: String, icon: NSImage, isEditing: Bool) {
    iconView.image = icon
    titleLabel.stringValue = title
    if titleField.stringValue != title {
      titleField.stringValue = title
    }
    titleLabel.isHidden = isEditing
    titleField.isHidden = !isEditing
  }

  @objc
  private func titleFieldChanged() {
    onTitleChange?(titleField.stringValue)
  }
}

extension DetailIdentityView: NSTextFieldDelegate {
  func controlTextDidChange(_ notification: Notification) {
    onTitleChange?(titleField.stringValue)
  }
}
