import AppKit

/// A centered SF Symbol + title + message, used whenever a column has nothing to show yet.
/// Shared by the item list and detail placeholders so both empty states look consistent.
@MainActor
final class EmptyStateView: NSView {
  private let imageView = NSImageView()
  private let titleField = NSTextField(labelWithString: "")
  private let messageField = NSTextField(wrappingLabelWithString: "")

  init() {
    super.init(frame: .zero)
    configureSubviews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func configureSubviews() {
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.symbolConfiguration = .init(pointSize: 40, weight: .regular)
    imageView.contentTintColor = .tertiaryLabelColor

    titleField.translatesAutoresizingMaskIntoConstraints = false
    titleField.font = .systemFont(ofSize: 16, weight: .semibold)
    titleField.textColor = .secondaryLabelColor
    titleField.alignment = .center

    messageField.translatesAutoresizingMaskIntoConstraints = false
    messageField.font = .systemFont(ofSize: 12)
    messageField.textColor = .tertiaryLabelColor
    messageField.alignment = .center
    messageField.maximumNumberOfLines = 3

    let stack = NSStackView(views: [imageView, titleField, messageField])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false

    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
    ])
  }

  func configure(symbolName: String, title: String, message: String?) {
    imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    titleField.stringValue = title
    messageField.stringValue = message ?? ""
    messageField.isHidden = message == nil
  }
}
