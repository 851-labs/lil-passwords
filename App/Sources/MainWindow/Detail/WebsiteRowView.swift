import AppKit

/// A read-mode "Websites" row: the URL rendered as a clickable link that opens in the default
/// browser.
@MainActor
final class WebsiteRowView: NSView {
  private let valueField = NSTextField(labelWithString: "")
  private let openButton = NSButton(
    image: NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: "Open in Browser")
      ?? NSImage(),
    target: nil,
    action: nil
  )
  private var url: URL?

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

    valueField.font = .systemFont(ofSize: 13)
    valueField.textColor = .linkColor
    valueField.lineBreakMode = .byTruncatingTail
    valueField.translatesAutoresizingMaskIntoConstraints = false

    openButton.isBordered = false
    openButton.bezelStyle = .inline
    openButton.contentTintColor = .secondaryLabelColor
    openButton.toolTip = "Open in Browser"
    openButton.target = self
    openButton.action = #selector(openTapped)
    openButton.translatesAutoresizingMaskIntoConstraints = false

    addSubview(valueField)
    addSubview(openButton)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 36),

      valueField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      valueField.centerYAnchor.constraint(equalTo: centerYAnchor),
      valueField.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -6),

      openButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      openButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      openButton.widthAnchor.constraint(equalToConstant: 22),
      openButton.heightAnchor.constraint(equalToConstant: 22),
    ])

    let click = NSClickGestureRecognizer(target: self, action: #selector(openTapped))
    valueField.addGestureRecognizer(click)
  }

  func configure(url: URL) {
    self.url = url
    valueField.stringValue = url.absoluteString
  }

  @objc
  private func openTapped() {
    guard let url else { return }
    NSWorkspace.shared.open(url)
  }
}
