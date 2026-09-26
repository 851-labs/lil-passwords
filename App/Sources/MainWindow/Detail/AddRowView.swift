import AppKit

/// A single tappable row styled like an inline action — the trailing "+" row at the bottom of
/// an editable list ("Add Username", "Add Website"), or a destructive action like "Remove
/// Verification Code".
@MainActor
final class AddRowView: NSView {
  private let action: () -> Void

  init(
    title: String,
    symbolName: String = "plus.circle.fill",
    tintColor: NSColor = .controlAccentColor,
    action: @escaping () -> Void
  ) {
    self.action = action
    super.init(frame: .zero)
    configureSubviews(title: title, symbolName: symbolName, tintColor: tintColor)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func configureSubviews(title: String, symbolName: String, tintColor: NSColor) {
    translatesAutoresizingMaskIntoConstraints = false

    let button = NSButton(
      title: title,
      image: NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage(),
      target: self,
      action: #selector(tapped)
    )
    button.imagePosition = .imageLeading
    button.isBordered = false
    button.bezelStyle = .inline
    button.contentTintColor = tintColor
    button.alignment = .left
    button.translatesAutoresizingMaskIntoConstraints = false

    addSubview(button)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
      button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
      button.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @objc
  private func tapped() {
    action()
  }
}
