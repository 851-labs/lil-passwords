import AppKit

/// A read-mode row: a label on the left, a value on the right, and a copy button that fades in
/// on hover. Used for user name and (with `isSecret`) password rows.
///
/// Apple Passwords reveals a masked value both on hover and on click; `onHoverChange` and
/// `onClickValue` let a `PasswordRowView` wire up exactly that, while a plain user-name row can
/// leave both `nil` and just get the copy affordance.
@MainActor
final class DetailValueRowView: NSView {
  // 851-2426 tophat accessibility audit: this row's Copy button used to be unreachable by
  // keyboard/VoiceOver at rest (`isHidden = true` until a mouse hover flipped it) — see
  // `HoverRevealButton`'s doc comment for why that's wrong and what replaces it. `isEligible`
  // tracks whether there's actually something to copy right now.
  var onCopy: (() -> Void)? {
    didSet { copyButton.isEligible = onCopy != nil }
  }
  var onClickValue: (() -> Void)?
  var onHoverChange: ((Bool) -> Void)?

  let labelField = NSTextField(labelWithString: "")
  let valueField = NSTextField(labelWithString: "")
  private let copyButton = HoverRevealButton(
    image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy") ?? NSImage(),
    target: nil,
    action: nil
  )
  private var trackingArea: NSTrackingArea?

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

    labelField.font = .systemFont(ofSize: 13)
    labelField.setContentHuggingPriority(.required, for: .horizontal)
    labelField.translatesAutoresizingMaskIntoConstraints = false

    valueField.font = .systemFont(ofSize: 13)
    valueField.textColor = .secondaryLabelColor
    valueField.alignment = .right
    valueField.lineBreakMode = .byTruncatingMiddle
    valueField.translatesAutoresizingMaskIntoConstraints = false

    copyButton.isBordered = false
    copyButton.bezelStyle = .inline
    copyButton.contentTintColor = .secondaryLabelColor
    // Nothing to copy yet — `onCopy` is set right after construction by every call site, which
    // flips this back via its `didSet` above.
    copyButton.isEligible = false
    copyButton.toolTip = "Copy"
    copyButton.target = self
    copyButton.action = #selector(copyTapped)
    copyButton.translatesAutoresizingMaskIntoConstraints = false
    // A generic "Copy" (851-2426) doesn't say what's being copied when several of these rows
    // (username, password, …) are on screen at once — `configure(label:value:)` below refines it
    // to "Copy Username"/"Copy Password" once the row's own label is known.
    copyButton.setAccessibilityLabel("Copy")

    addSubview(labelField)
    addSubview(valueField)
    addSubview(copyButton)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 36),

      // 16pt, matching `CardView`'s divider inset (851-2463/#32) and `KeyValueRow`'s own label
      // inset, so this row's text lines up with the "Created" row's `KeyValueRow` above/below it
      // and with the dividers between them, instead of jogging in/out by 4pt at each boundary.
      labelField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      labelField.centerYAnchor.constraint(equalTo: centerYAnchor),

      valueField.leadingAnchor.constraint(greaterThanOrEqualTo: labelField.trailingAnchor, constant: 8),
      valueField.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -6),
      valueField.centerYAnchor.constraint(equalTo: centerYAnchor),

      copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      copyButton.widthAnchor.constraint(equalToConstant: 22),
      copyButton.heightAnchor.constraint(equalToConstant: 22),
    ])

    let click = NSClickGestureRecognizer(target: self, action: #selector(valueClicked))
    valueField.addGestureRecognizer(click)
  }

  func configure(label: String, value: String) {
    labelField.stringValue = label
    valueField.stringValue = value
    copyButton.setAccessibilityLabel("Copy \(label)")
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    copyButton.isHovering = true
    onHoverChange?(true)
  }

  override func mouseExited(with event: NSEvent) {
    copyButton.isHovering = false
    onHoverChange?(false)
  }

  @objc
  private func copyTapped() {
    onCopy?()
    CopyHUD.show(relativeTo: copyButton.bounds, of: copyButton)
  }

  @objc
  private func valueClicked() {
    onClickValue?()
  }
}
