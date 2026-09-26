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
    imageView.imageScaling = .scaleProportionallyUpOrDown
    // SF Symbols report varying intrinsic sizes at the same point size (a shield glyph isn't the
    // same height as a key), which is what let the image and title overlap in some categories.
    // Pin the image view to a fixed box so every symbol lays out identically.
    imageView.setContentHuggingPriority(.required, for: .vertical)
    imageView.setContentCompressionResistancePriority(.required, for: .vertical)

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
    stack.spacing = 8
    stack.setCustomSpacing(12, after: imageView)
    stack.translatesAutoresizingMaskIntoConstraints = false

    addSubview(stack)
    NSLayoutConstraint.activate([
      imageView.widthAnchor.constraint(equalToConstant: 44),
      imageView.heightAnchor.constraint(equalToConstant: 44),
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
