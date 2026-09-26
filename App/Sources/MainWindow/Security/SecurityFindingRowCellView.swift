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
    reasonField.maximumNumberOfLines = 3

    changePasswordButton.translatesAutoresizingMaskIntoConstraints = false
    changePasswordButton.title = "Change Password on Website"
    changePasswordButton.bezelStyle = .rounded
    changePasswordButton.controlSize = .small
    changePasswordButton.target = self
    changePasswordButton.action = #selector(changePasswordTapped)

    hideWarningButton.translatesAutoresizingMaskIntoConstraints = false
    hideWarningButton.title = "Hide Security Warning"
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
  }

  @objc
  private func changePasswordTapped() {
    onChangePasswordTapped?()
  }

  @objc
  private func hideWarningTapped() {
    onHideWarningTapped?()
  }
}
