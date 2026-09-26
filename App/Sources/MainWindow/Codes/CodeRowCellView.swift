import AppKit
import LilPasswordsKit

/// A single row in the Codes view (851-2418): monogram icon, item title + issuer/account
/// subtitle, the live 6/8-digit code, and a countdown ring showing how long it's valid for.
///
/// Clicking a row copies its current code to the pasteboard (``CodesViewController`` drives that
/// from table selection) — this view's own job is just to flash a "Copied" confirmation in place
/// of the countdown ring for a moment, via ``flashCopied()``.
final class CodeRowCellView: NSTableCellView {
  static let reuseIdentifier = NSUserInterfaceItemIdentifier("CodeRow")

  private let iconView = NSImageView()
  private let titleField = NSTextField(labelWithString: "")
  private let subtitleField = NSTextField(labelWithString: "")
  private let codeField = NSTextField(labelWithString: "")
  private let ringView = CountdownRingView()
  private let copiedLabel = NSTextField(labelWithString: "Copied")

  /// The item currently bound to this cell, kept so a stray, already-scheduled `flashCopied()`
  /// from a previous row (before reuse) can't paint over a different item's cell.
  private(set) var boundItemID: UUID?

  static func dequeue(from tableView: NSTableView, owner: Any?) -> CodeRowCellView {
    if let existing = tableView.makeView(withIdentifier: reuseIdentifier, owner: owner) as? CodeRowCellView {
      return existing
    }
    return CodeRowCellView()
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
    titleField.font = .systemFont(ofSize: 13)
    titleField.lineBreakMode = .byTruncatingTail

    subtitleField.translatesAutoresizingMaskIntoConstraints = false
    subtitleField.font = .systemFont(ofSize: 11)
    subtitleField.textColor = .secondaryLabelColor
    subtitleField.lineBreakMode = .byTruncatingTail

    codeField.translatesAutoresizingMaskIntoConstraints = false
    codeField.font = .monospacedDigitSystemFont(ofSize: 20, weight: .medium)
    codeField.alignment = .right

    copiedLabel.translatesAutoresizingMaskIntoConstraints = false
    copiedLabel.font = .systemFont(ofSize: 11, weight: .semibold)
    copiedLabel.textColor = .secondaryLabelColor
    copiedLabel.alignment = .right
    copiedLabel.isHidden = true

    ringView.translatesAutoresizingMaskIntoConstraints = false

    addSubview(iconView)
    addSubview(titleField)
    addSubview(subtitleField)
    addSubview(codeField)
    addSubview(copiedLabel)
    addSubview(ringView)

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 28),
      iconView.heightAnchor.constraint(equalToConstant: 28),

      titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
      titleField.topAnchor.constraint(equalTo: topAnchor, constant: 8),

      subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
      subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),

      ringView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      ringView.centerYAnchor.constraint(equalTo: centerYAnchor),
      ringView.widthAnchor.constraint(equalToConstant: 18),
      ringView.heightAnchor.constraint(equalToConstant: 18),

      codeField.trailingAnchor.constraint(equalTo: ringView.leadingAnchor, constant: -10),
      codeField.centerYAnchor.constraint(equalTo: centerYAnchor),
      codeField.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 12),

      copiedLabel.trailingAnchor.constraint(equalTo: codeField.trailingAnchor),
      copiedLabel.centerYAnchor.constraint(equalTo: codeField.centerYAnchor),
    ])
  }

  /// Binds the cell to `item` and shows its code/ring as of `now`. `item.totp` is assumed
  /// non-`nil` — ``CodesViewController`` only ever rows items that passed
  /// `PasswordItem.withVerificationCode()`.
  func configure(with item: PasswordItem, at now: Date) {
    boundItemID = item.id
    iconView.image = MonogramIcon.icon(for: item.title)
    titleField.stringValue = item.title
    subtitleField.stringValue = subtitleText(for: item)
    copiedLabel.isHidden = true
    codeField.isHidden = false
    ringView.isHidden = false
    if let totp = item.totp {
      updateLiveValues(totp: totp, at: now)
    } else {
      codeField.stringValue = ""
    }
  }

  /// Refreshes only the code text and countdown ring, without touching the icon/title/subtitle —
  /// called once a second by `CodesViewController` for every currently-visible row, so a tick
  /// doesn't need a full `NSTableView.reloadData()` (which would also disturb selection/animation
  /// state).
  func updateLiveValues(totp: TOTP, at now: Date) {
    codeField.stringValue = Self.formattedCode(totp.code(at: now))
    ringView.update(totp: totp, at: now)
  }

  /// Briefly swaps the code for a "Copied" confirmation, matching the momentary feedback Apple
  /// Passwords shows after a click-to-copy gesture.
  func flashCopied(for itemID: UUID) {
    guard boundItemID == itemID else { return }
    codeField.isHidden = true
    ringView.isHidden = true
    copiedLabel.isHidden = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
      guard let self, self.boundItemID == itemID else { return }
      self.copiedLabel.isHidden = true
      self.codeField.isHidden = false
      self.ringView.isHidden = false
    }
  }

  /// Splits a 6- or 8-digit code into two groups ("123 456"), matching how authenticator apps
  /// display codes to make them easier to read/type.
  private static func formattedCode(_ code: String) -> String {
    guard code.count == 6 || code.count == 8 else { return code }
    let midpoint = code.index(code.startIndex, offsetBy: code.count / 2)
    return "\(code[code.startIndex..<midpoint]) \(code[midpoint...])"
  }

  private func subtitleText(for item: PasswordItem) -> String {
    if let uri = item.totpURI, let url = URL(string: uri), let parsed = try? OTPAuthURI(url: url) {
      if let issuer = parsed.issuer, !issuer.isEmpty, issuer != item.title {
        return "\(issuer) · \(parsed.accountName)"
      }
      return parsed.accountName
    }
    return item.usernames.first(where: { !$0.isEmpty }) ?? ""
  }
}
