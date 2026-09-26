import AppKit

/// The edit-mode "Password" row: a secure (dot-masked) field by default, with a reveal button
/// that swaps in a plain-text field showing the same value. `NSSecureTextField` can't toggle
/// masking on an existing instance, so this keeps two fields in sync and shows only one.
@MainActor
final class PasswordEditRowView: NSView {
  var onValueChange: ((String) -> Void)?

  private let secureField = NSSecureTextField()
  private let plainField = NSTextField()
  private let revealButton = NSButton(
    image: NSImage(systemSymbolName: "eye", accessibilityDescription: "Reveal Password") ?? NSImage(),
    target: nil,
    action: nil
  )
  private var isRevealed = false

  init(value: String) {
    super.init(frame: .zero)
    configureSubviews(value: value)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func configureSubviews(value: String) {
    translatesAutoresizingMaskIntoConstraints = false

    for field in [secureField, plainField] as [NSTextField] {
      field.stringValue = value
      field.placeholderString = "Password"
      field.isBordered = false
      field.drawsBackground = false
      field.font = .systemFont(ofSize: 13)
      field.delegate = self
      field.translatesAutoresizingMaskIntoConstraints = false
    }
    plainField.isHidden = true

    revealButton.isBordered = false
    revealButton.bezelStyle = .inline
    revealButton.contentTintColor = .secondaryLabelColor
    revealButton.toolTip = "Reveal Password"
    revealButton.target = self
    revealButton.action = #selector(revealTapped)
    revealButton.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView(views: [secureField, plainField, revealButton])
    stack.orientation = .horizontal
    stack.spacing = 6
    // 16pt leading — see `DetailValueRowView`'s matching comment: lines this row's field up with
    // `CardView`'s divider inset and `KeyValueRow`'s own label inset.
    stack.edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 6, right: 8)
    stack.translatesAutoresizingMaskIntoConstraints = false

    addSubview(stack)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      revealButton.widthAnchor.constraint(equalToConstant: 20),
    ])
  }

  @objc
  private func revealTapped() {
    isRevealed.toggle()
    secureField.isHidden = isRevealed
    plainField.isHidden = !isRevealed
    revealButton.image = NSImage(
      systemSymbolName: isRevealed ? "eye.slash" : "eye",
      accessibilityDescription: "Reveal Password"
    )
    if isRevealed {
      window?.makeFirstResponder(plainField)
    } else {
      window?.makeFirstResponder(secureField)
    }
  }
}

extension PasswordEditRowView: NSTextFieldDelegate {
  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSTextField else { return }
    let value = field.stringValue
    // Keep the hidden twin in sync so toggling reveal never loses an edit made while the other
    // field was visible.
    secureField.stringValue = value
    plainField.stringValue = value
    onValueChange?(value)
  }
}
