import AppKit
import LilPasswordsKit

/// A single item row in the item list: monogram icon, title, and username as secondary text —
/// the Apple Passwords item-row layout (851-2414), with a 40pt icon and a hairline separator
/// inset to start at the text rather than under the icon (851-2463).
final class ItemRowCellView: NSTableCellView {
  static let reuseIdentifier = NSUserInterfaceItemIdentifier("ItemRow")

  private let iconView = NSImageView()
  private let titleField = NSTextField(labelWithString: "")
  private let subtitleField = NSTextField(labelWithString: "")
  private let separator = NSBox()

  /// 851-2459: cancelled and replaced every `configure(with:hidesSeparator:)` call so a slow
  /// fetch for a row this cell used to represent can never land after `NSTableView` has recycled
  /// the cell for a different item.
  private var iconLoadTask: Task<Void, Never>?

  static func dequeue(from tableView: NSTableView, owner: Any?) -> ItemRowCellView {
    if let existing = tableView.makeView(withIdentifier: reuseIdentifier, owner: owner) as? ItemRowCellView {
      return existing
    }
    return ItemRowCellView()
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    identifier = Self.reuseIdentifier
    configureSubviews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func configureSubviews() {
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.imageScaling = .scaleProportionallyUpOrDown

    titleField.translatesAutoresizingMaskIntoConstraints = false
    titleField.font = .boldSystemFont(ofSize: 13)
    titleField.lineBreakMode = .byTruncatingTail

    subtitleField.translatesAutoresizingMaskIntoConstraints = false
    subtitleField.font = .systemFont(ofSize: 11)
    subtitleField.textColor = .secondaryLabelColor
    subtitleField.lineBreakMode = .byTruncatingTail

    separator.boxType = .separator
    separator.translatesAutoresizingMaskIntoConstraints = false

    addSubview(iconView)
    addSubview(titleField)
    addSubview(subtitleField)
    addSubview(separator)

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 40),
      iconView.heightAnchor.constraint(equalToConstant: 40),

      titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
      titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
      titleField.topAnchor.constraint(equalTo: topAnchor, constant: 9),

      subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
      subtitleField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
      subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),

      // Inset to start at the text, not under the icon, matching Apple Passwords (851-2463).
      separator.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
      separator.trailingAnchor.constraint(equalTo: trailingAnchor),
      separator.bottomAnchor.constraint(equalTo: bottomAnchor),
      separator.heightAnchor.constraint(equalToConstant: 1),
    ])
  }

  /// - Parameter hidesSeparator: Whether this row's bottom hairline should be hidden — true when
  ///   this row, or the row immediately below it, is selected, so no hairline ever cuts through a
  ///   rounded selection highlight (851-2463). Kept in sync after the initial `configure` call by
  ///   `setSeparatorHidden(_:)`, since selection changes don't re-invoke `configure`.
  func configure(with item: PasswordItem, hidesSeparator: Bool) {
    iconLoadTask?.cancel()
    iconView.image = MonogramIcon.icon(for: item.title, dimension: 40)
    titleField.stringValue = item.title
    let subtitle = item.usernames.first(where: { !$0.isEmpty })
    subtitleField.stringValue = subtitle ?? ""
    subtitleField.isHidden = subtitle == nil
    separator.isHidden = hidesSeparator

    let host = item.websites.first?.host
    iconLoadTask = WebsiteIconLoader.loadIcon(forHost: host) { [weak self] icon in
      self?.iconView.image = icon
    }

    // A meaningful VoiceOver description for the whole row (851-2426) — "Amazon, jordan@…, has
    // verification code" is the exact shape the ticket calls out — rather than just the title a
    // plain `NSTableCellView` would otherwise expose via its subviews individually.
    setAccessibilityElement(true)
    setAccessibilityLabel(
      accessibilityLabel(title: item.title, subtitle: subtitle, hasVerificationCode: item.totpURI != nil))
  }

  private func accessibilityLabel(title: String, subtitle: String?, hasVerificationCode: Bool) -> String {
    var parts = [title]
    if let subtitle { parts.append(subtitle) }
    if hasVerificationCode { parts.append(String(localized: "has verification code")) }
    return parts.joined(separator: ", ")
  }

  func setSeparatorHidden(_ hidden: Bool) {
    separator.isHidden = hidden
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    iconLoadTask?.cancel()
    iconLoadTask = nil
  }
}
