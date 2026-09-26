import AppKit
import LilPasswordsKit

/// A single flagged item in the Security view (851-2419): icon, title, Apple-style reason text
/// for why it's flagged, and the two actions Apple Passwords offers per finding — "Change
/// Password on Website" (opens the item's `.well-known/change-password` URL) and "Hide Security
/// Warning" (dismisses this specific finding for this item).
final class SecurityFindingRowCellView: NSTableCellView {
  static let reuseIdentifier = NSUserInterfaceItemIdentifier("SecurityFindingRow")

  private let iconView = NSImageView()
  private let titleField = NSTextField(labelWithString: "")
  private let reasonField = NSTextField(wrappingLabelWithString: "")
  private let changePasswordButton = NSButton()
  private let hideWarningButton = NSButton()

  /// Set fresh on every `configure(...)` call — cells are reused across rows, so a stale closure
  /// from a previous item must never fire.
  var onChangePasswordTapped: (() -> Void)?
  var onHideWarningTapped: (() -> Void)?

  static func dequeue(from tableView: NSTableView, owner: Any?) -> SecurityFindingRowCellView {
    if let existing = tableView.makeView(withIdentifier: reuseIdentifier, owner: owner) as? SecurityFindingRowCellView {
      return existing
    }
    return SecurityFindingRowCellView()
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
    titleField.font = .systemFont(ofSize: 13, weight: .semibold)

    reasonField.translatesAutoresizingMaskIntoConstraints = false
    reasonField.font = .systemFont(ofSize: 11)
    reasonField.textColor = .secondaryLabelColor
    // Was capped at 3 lines, which clipped the (longer) reused-password reason text mid-sentence
    // — "…change your password on each" (851-2426 review note). Unlimited lines plus
    // `height(for:availableWidth:)` below sizing the row to match is the actual fix; the cap
    // alone was never the right tool here since the row's height was still fixed regardless.
    reasonField.maximumNumberOfLines = 0

    changePasswordButton.translatesAutoresizingMaskIntoConstraints = false
    changePasswordButton.title = String(localized: "Change Password on Website")
    changePasswordButton.bezelStyle = .rounded
    changePasswordButton.controlSize = .small
    changePasswordButton.target = self
    changePasswordButton.action = #selector(changePasswordTapped)

    hideWarningButton.translatesAutoresizingMaskIntoConstraints = false
    hideWarningButton.title = String(localized: "Hide Security Warning")
    hideWarningButton.bezelStyle = .rounded
    hideWarningButton.controlSize = .small
    hideWarningButton.target = self
    hideWarningButton.action = #selector(hideWarningTapped)

    let buttonRow = NSStackView(views: [changePasswordButton, hideWarningButton])
    buttonRow.orientation = .horizontal
    buttonRow.spacing = 8
    buttonRow.translatesAutoresizingMaskIntoConstraints = false

    addSubview(iconView)
    addSubview(titleField)
    addSubview(reasonField)
    addSubview(buttonRow)

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      iconView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      iconView.widthAnchor.constraint(equalToConstant: 28),
      iconView.heightAnchor.constraint(equalToConstant: 28),

      titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
      titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
      titleField.topAnchor.constraint(equalTo: topAnchor, constant: 10),

      reasonField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
      reasonField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      reasonField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 4),

      buttonRow.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
      buttonRow.topAnchor.constraint(equalTo: reasonField.bottomAnchor, constant: 8),
      buttonRow.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
    ])
  }

  func configure(item: PasswordItem, kind: SecurityIssueKind) {
    iconView.image = MonogramIcon.icon(for: item.title)
    titleField.stringValue = item.title
    reasonField.stringValue = kind.reasonText
    changePasswordButton.isEnabled = item.changePasswordURL != nil

    // A meaningful VoiceOver description for the whole row (851-2426), not just the title.
    setAccessibilityElement(true)
    setAccessibilityLabel(String(localized: "\(item.title), \(kind.groupTitle.lowercased()): \(kind.reasonText)"))
  }

  @objc
  private func changePasswordTapped() {
    onChangePasswordTapped?()
  }

  @objc
  private func hideWarningTapped() {
    onHideWarningTapped?()
  }

  // MARK: - Height measurement

  /// A reusable, never-displayed button whose `fittingSize` stands in for the real button row's
  /// height in ``height(for:availableWidth:)`` below — `.small`/`.rounded` push buttons have a
  /// fixed height independent of their title, so one instance covers both real buttons.
  private static let sampleButton: NSButton = {
    let button = NSButton(title: String(localized: "Change Password on Website"), target: nil, action: nil)
    button.bezelStyle = .rounded
    button.controlSize = .small
    return button
  }()

  /// This row's exact height for `kind`'s reason text wrapped to fit `availableWidth` (the
  /// table's own width, since the single column tracks it) — mirrors `configureSubviews()`'s
  /// layout constants exactly, so `SecurityViewController.tableView(_:heightOfRow:)` can size the
  /// row to actually fit the text instead of guessing a fixed height that clips it.
  static func height(for kind: SecurityIssueKind, availableWidth: CGFloat) -> CGFloat {
    let topInset: CGFloat = 10
    let bottomInset: CGFloat = 10
    let titleReasonGap: CGFloat = 4
    let reasonButtonGap: CGFloat = 8
    // leading(8) + icon(28) + icon-to-text gap(8) + reason's own trailing inset(12).
    let horizontalInset: CGFloat = 8 + 28 + 8 + 12
    let reasonWidth = max(0, availableWidth - horizontalInset)

    let titleHeight = measuredHeight(
      for: "Title", font: .systemFont(ofSize: 13, weight: .semibold), width: .greatestFiniteMagnitude)
    let reasonHeight = measuredHeight(for: kind.reasonText, font: .systemFont(ofSize: 11), width: reasonWidth)
    let buttonRowHeight = sampleButton.fittingSize.height
    let iconHeight: CGFloat = 28

    let textColumnHeight = titleHeight + titleReasonGap + reasonHeight + reasonButtonGap + buttonRowHeight
    return ceil(topInset + max(iconHeight, textColumnHeight) + bottomInset)
  }

  private static func measuredHeight(for text: String, font: NSFont, width: CGFloat) -> CGFloat {
    guard width > 0 else { return 0 }
    let bounds = NSAttributedString(string: text, attributes: [.font: font])
      .boundingRect(
        with: NSSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading])
    return ceil(bounds.height)
  }
}
