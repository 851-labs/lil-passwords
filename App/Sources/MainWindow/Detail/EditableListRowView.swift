import AppKit

/// One editable row in a reorderable list (usernames or websites in edit mode): up/down
/// reorder buttons, a text field, and a remove button.
@MainActor
final class EditableListRowView: NSView {
  var onValueChange: ((String) -> Void)?
  var onMoveUp: (() -> Void)?
  var onMoveDown: (() -> Void)?
  var onRemove: (() -> Void)?

  private let textField = NSTextField()

  init(value: String, placeholder: String, canMoveUp: Bool, canMoveDown: Bool) {
    super.init(frame: .zero)
    configureSubviews(value: value, placeholder: placeholder, canMoveUp: canMoveUp, canMoveDown: canMoveDown)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func configureSubviews(value: String, placeholder: String, canMoveUp: Bool, canMoveDown: Bool) {
    translatesAutoresizingMaskIntoConstraints = false

    textField.stringValue = value
    textField.placeholderString = placeholder
    textField.isBordered = false
    textField.drawsBackground = false
    textField.font = .systemFont(ofSize: 13)
    textField.delegate = self
    textField.translatesAutoresizingMaskIntoConstraints = false
    textField.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let upButton = Self.makeGlyphButton(symbolName: "chevron.up", enabled: canMoveUp, toolTip: "Move Up")
    upButton.target = self
    upButton.action = #selector(moveUpTapped)

    let downButton = Self.makeGlyphButton(symbolName: "chevron.down", enabled: canMoveDown, toolTip: "Move Down")
    downButton.target = self
    downButton.action = #selector(moveDownTapped)

    let removeButton = Self.makeGlyphButton(symbolName: "minus.circle.fill", enabled: true, toolTip: "Remove")
    removeButton.contentTintColor = .systemRed
    removeButton.target = self
    removeButton.action = #selector(removeTapped)

    let stack = NSStackView(views: [upButton, downButton, textField, removeButton])
    stack.orientation = .horizontal
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
    stack.translatesAutoresizingMaskIntoConstraints = false

    addSubview(stack)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      upButton.widthAnchor.constraint(equalToConstant: 16),
      downButton.widthAnchor.constraint(equalToConstant: 16),
      removeButton.widthAnchor.constraint(equalToConstant: 18),
    ])
  }

  private static func makeGlyphButton(symbolName: String, enabled: Bool, toolTip: String) -> NSButton {
    let button = NSButton(
      image: NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip) ?? NSImage(),
      target: nil,
      action: nil
    )
    button.isBordered = false
    button.bezelStyle = .inline
    button.contentTintColor = .secondaryLabelColor
    button.isEnabled = enabled
    button.toolTip = toolTip
    button.translatesAutoresizingMaskIntoConstraints = false
    return button
  }

  @objc
  private func moveUpTapped() {
    onMoveUp?()
  }

  @objc
  private func moveDownTapped() {
    onMoveDown?()
  }

  @objc
  private func removeTapped() {
    onRemove?()
  }
}

extension EditableListRowView: NSTextFieldDelegate {
  func controlTextDidChange(_ notification: Notification) {
    onValueChange?(textField.stringValue)
  }
}
