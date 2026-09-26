import AppKit

/// The leading toolbar item over the list column (851-2463): the current sidebar category's name
/// in bold, with an "N Items" subtitle below it — matching Apple Passwords' two-line toolbar
/// title. Replaces the list's own in-content "N Items" header row that sat above the table before
/// this ticket; `ItemListViewController` still computes the count, it just hands it here instead
/// of drawing it itself.
///
/// The deployment target is macOS 13 (see `project.yml`), so this uses a plain custom view rather
/// than `NSToolbarItem.subtitle` (macOS 14+).
@MainActor
final class ListTitleToolbarView: NSView {
  private let titleLabel = NSTextField(labelWithString: "")
  private let subtitleLabel = NSTextField(labelWithString: "")

  init() {
    super.init(frame: .zero)
    configureSubviews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func configureSubviews() {
    translatesAutoresizingMaskIntoConstraints = false

    titleLabel.font = .boldSystemFont(ofSize: 14)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    subtitleLabel.font = .systemFont(ofSize: 11)
    subtitleLabel.textColor = .secondaryLabelColor
    subtitleLabel.lineBreakMode = .byTruncatingTail
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView(views: [titleLabel, subtitleLabel])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 1
    stack.translatesAutoresizingMaskIntoConstraints = false

    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
    ])
  }

  /// - Parameters:
  ///   - title: The current sidebar category's name (e.g. "All", "Codes").
  ///   - subtitle: The item count line (e.g. "121 Items"), already pluralized by the caller.
  func configure(title: String, subtitle: String) {
    titleLabel.stringValue = title
    subtitleLabel.stringValue = subtitle
  }
}
