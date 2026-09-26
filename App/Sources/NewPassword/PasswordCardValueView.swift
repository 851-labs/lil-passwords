import AppKit

/// The New Password sheet's password value (851-2416): masked dots by default, revealed as an
/// editable plain-text field while the mouse hovers it or it has keyboard focus — matching Apple
/// Passwords' own New Password sheet. Clicking the masked dots focuses the field (and so reveals
/// it) even without first hovering long enough to trigger the hover reveal.
///
/// `NSSecureTextField` can't toggle its own masking on an existing instance, so — like the detail
/// pane's `PasswordEditRowView` — this keeps a masked field and a plain field in sync and shows
/// only one at a time.
@MainActor
final class PasswordCardValueView: NSView {
  var onValueChange: ((String) -> Void)?

  private let maskedField = NSTextField(labelWithString: "")
  private let plainField = NSTextField()
  private var value: String
  private var isFocused = false
  private var isHovering = false
  private var trackingArea: NSTrackingArea?

  init(value: String) {
    self.value = value
    super.init(frame: .zero)
    configureSubviews()
    updateDisplayedField()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func configureSubviews() {
    translatesAutoresizingMaskIntoConstraints = false

    maskedField.font = .systemFont(ofSize: 13)
    maskedField.textColor = .secondaryLabelColor
    maskedField.alignment = .right
    maskedField.lineBreakMode = .byTruncatingMiddle
    maskedField.translatesAutoresizingMaskIntoConstraints = false

    plainField.stringValue = value
    plainField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    plainField.textColor = .secondaryLabelColor
    plainField.alignment = .right
    plainField.isBordered = false
    plainField.drawsBackground = false
    plainField.lineBreakMode = .byTruncatingMiddle
    plainField.delegate = self
    plainField.translatesAutoresizingMaskIntoConstraints = false

    addSubview(plainField)
    addSubview(maskedField)

    NSLayoutConstraint.activate([
      plainField.leadingAnchor.constraint(equalTo: leadingAnchor),
      plainField.trailingAnchor.constraint(equalTo: trailingAnchor),
      plainField.topAnchor.constraint(equalTo: topAnchor),
      plainField.bottomAnchor.constraint(equalTo: bottomAnchor),

      maskedField.leadingAnchor.constraint(equalTo: leadingAnchor),
      maskedField.trailingAnchor.constraint(equalTo: trailingAnchor),
      maskedField.topAnchor.constraint(equalTo: topAnchor),
      maskedField.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    // The masked field sits on top and isn't itself editable, so a click needs its own gesture
    // recognizer to focus the (hidden-until-revealed) real field underneath.
    let click = NSClickGestureRecognizer(target: self, action: #selector(maskedFieldClicked))
    maskedField.addGestureRecognizer(click)
  }

  /// Replaces the current password (e.g. after Regenerate), keeping mask/reveal state as-is.
  func setValue(_ newValue: String) {
    value = newValue
    plainField.stringValue = newValue
    updateDisplayedField()
  }

  var stringValue: String { value }

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
    isHovering = true
    updateDisplayedField()
  }

  override func mouseExited(with event: NSEvent) {
    isHovering = false
    updateDisplayedField()
  }

  @objc
  private func maskedFieldClicked() {
    // Unhide `plainField` before asking it to become first responder — a hidden view can't
    // reliably take over as the field editor, so this can't just flip `isFocused` and rely on
    // `controlTextDidBeginEditing` to unhide it after the fact (same ordering `PasswordEditRowView`
    // relies on for its own reveal button).
    isFocused = true
    updateDisplayedField()
    window?.makeFirstResponder(plainField)
  }

  private func updateDisplayedField() {
    let isRevealed = isHovering || isFocused
    maskedField.stringValue = String(repeating: "•", count: max(value.count, 8))
    maskedField.isHidden = isRevealed
    plainField.isHidden = !isRevealed
  }
}

extension PasswordCardValueView: NSTextFieldDelegate {
  func controlTextDidBeginEditing(_ notification: Notification) {
    isFocused = true
    updateDisplayedField()
  }

  func controlTextDidEndEditing(_ notification: Notification) {
    isFocused = false
    updateDisplayedField()
  }

  func controlTextDidChange(_ notification: Notification) {
    value = plainField.stringValue
    onValueChange?(value)
  }
}
