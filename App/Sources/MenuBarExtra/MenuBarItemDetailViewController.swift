import AppKit
import LilPasswordsKit

@MainActor
protocol MenuBarItemDetailViewControllerDelegate: AnyObject {
  func menuBarItemDetailViewControllerDidRequestBack(_ controller: MenuBarItemDetailViewController)
  func menuBarItemDetailViewControllerDidRequestOpenApp(_ controller: MenuBarItemDetailViewController)
}

/// An item's detail inside the popover (851-2425): monogram/title header, then one rounded card
/// of label-left/value-right rows (User Name, Password as dots, Verification Code with a live
/// countdown ring) — matching Apple Passwords' own menu bar extra and the main window's own detail
/// pane card style (`DetailSectionContainerView`, reused directly here rather than duplicated).
/// Never shows a secret "at rest": clicking a row is what copies it (via `Pasteboard.copySecret`),
/// with a brief "Copied" confirmation (`CopyHUD`, also reused from the main window). The
/// Verification Code row is only shown when the item actually has a TOTP secret, and its code/ring
/// live-update every second off ``TOTP/nextChange(after:)`` — this controller computes that
/// locally rather than round-tripping through `AgentClient.totpCode(_:)` since it already holds
/// the full `PasswordItem` (including `totpURI`) handed to it by `MenuBarListViewController`.
@MainActor
final class MenuBarItemDetailViewController: NSViewController {
  weak var delegate: MenuBarItemDetailViewControllerDelegate?

  private var item: PasswordItem?
  private var totpTimer: Timer?

  private let iconView = NSImageView()
  private let titleField = NSTextField(labelWithString: "")
  private let subtitleField = NSTextField(labelWithString: "")
  private let card = DetailSectionContainerView()
  private let usernameRow = MenuBarCopyableRowView()
  private let passwordRow = MenuBarCopyableRowView()
  private let codeRow = MenuBarCopyableRowView()
  private let footerButton = NSButton()

  override func loadView() {
    let view = NSView()

    let backButton = NSButton(
      image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: String(localized: "Back"))!,
      target: self,
      action: #selector(backTapped)
    )
    backButton.bezelStyle = .accessoryBarAction
    backButton.isBordered = false
    backButton.translatesAutoresizingMaskIntoConstraints = false
    backButton.setAccessibilityLabel(String(localized: "Back"))

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.imageScaling = .scaleProportionallyUpOrDown

    titleField.font = .systemFont(ofSize: 15, weight: .semibold)
    titleField.alignment = .center
    titleField.translatesAutoresizingMaskIntoConstraints = false

    subtitleField.font = .systemFont(ofSize: 12)
    subtitleField.textColor = .secondaryLabelColor
    subtitleField.alignment = .center
    subtitleField.translatesAutoresizingMaskIntoConstraints = false

    let headerStack = NSStackView(views: [iconView, titleField, subtitleField])
    headerStack.orientation = .vertical
    headerStack.alignment = .centerX
    headerStack.spacing = 4
    headerStack.setCustomSpacing(8, after: iconView)
    headerStack.translatesAutoresizingMaskIntoConstraints = false

    let footerSeparator = NSBox()
    footerSeparator.boxType = .separator
    footerSeparator.translatesAutoresizingMaskIntoConstraints = false

    footerButton.title = String(localized: "Open \(LilPasswordsKit.productName)")
    footerButton.bezelStyle = .accessoryBarAction
    footerButton.controlSize = .small
    footerButton.target = self
    footerButton.action = #selector(openAppTapped)
    footerButton.translatesAutoresizingMaskIntoConstraints = false

    view.addSubview(backButton)
    view.addSubview(headerStack)
    view.addSubview(card)
    view.addSubview(footerSeparator)
    view.addSubview(footerButton)

    NSLayoutConstraint.activate([
      backButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
      backButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),

      iconView.widthAnchor.constraint(equalToConstant: 44),
      iconView.heightAnchor.constraint(equalToConstant: 44),

      headerStack.topAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 4),
      headerStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      headerStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
      headerStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),

      card.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 18),
      card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

      footerSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      footerSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      footerSeparator.bottomAnchor.constraint(equalTo: footerButton.topAnchor, constant: -6),
      footerSeparator.topAnchor.constraint(greaterThanOrEqualTo: card.bottomAnchor, constant: 16),

      footerButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
      footerButton.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -10),
      footerButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
    ])

    self.view = view
  }

  isolated deinit {
    totpTimer?.invalidate()
  }

  /// Populates every field for `item`, rebuilds the card's rows, and (re)starts the TOTP
  /// countdown, if any. Safe to call repeatedly with a different item — e.g. selecting another
  /// suggested item without dismissing the popover first.
  func configure(with item: PasswordItem) {
    self.item = item
    iconView.image = MonogramIcon.icon(for: item.title, dimension: 44)
    titleField.stringValue = item.title
    let username = item.usernames.first(where: { !$0.isEmpty })
    subtitleField.stringValue = username ?? ""
    subtitleField.isHidden = username == nil

    usernameRow.configure(label: String(localized: "User Name"), value: username ?? "", showRing: false)
    usernameRow.onCopy = { [weak self] in
      guard let username = self?.item?.usernames.first(where: { !$0.isEmpty }) else { return }
      Pasteboard.copySecret(username)
    }

    passwordRow.configure(
      label: String(localized: "Password"), value: String(repeating: "•", count: max(item.password.count, 8)),
      showRing: false)
    passwordRow.onCopy = { [weak self] in
      guard let password = self?.item?.password else { return }
      Pasteboard.copySecret(password)
    }

    codeRow.onCopy = { [weak self] in
      guard let totp = self?.item?.totp else { return }
      Pasteboard.copySecret(totp.code(at: Date()))
    }

    var rows: [NSView] = []
    if username != nil {
      rows.append(usernameRow)
    }
    rows.append(passwordRow)
    if item.totp != nil {
      rows.append(codeRow)
    }
    card.setRows(rows)

    restartTOTPCountdownIfNeeded()
  }

  private func restartTOTPCountdownIfNeeded() {
    totpTimer?.invalidate()
    totpTimer = nil
    guard item?.totp != nil else { return }
    updateVerificationCodeRow()
    totpTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.updateVerificationCodeRow() }
    }
  }

  private func updateVerificationCodeRow() {
    guard let totp = item?.totp else { return }
    let now = Date()
    codeRow.configure(label: String(localized: "Verification Code"), value: totp.code(at: now), showRing: true)
    let elapsed = now.timeIntervalSince1970.truncatingRemainder(dividingBy: totp.period)
    codeRow.updateRingFraction(elapsed / totp.period)
  }

  @objc private func backTapped() {
    delegate?.menuBarItemDetailViewControllerDidRequestBack(self)
  }

  @objc private func openAppTapped() {
    delegate?.menuBarItemDetailViewControllerDidRequestOpenApp(self)
  }
}
