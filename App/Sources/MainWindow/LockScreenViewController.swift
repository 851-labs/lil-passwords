import AppKit
import LilPasswordsKit

/// Told when the user wants to authenticate. `MainWindowController` is the real conformer: it
/// owns the `LockCoordinator` this view controller has no reference to, keeping this file free of
/// any XPC/`LAContext` dependency so it stays a plain, static view (easy to screenshot for
/// tophat, and with nothing here that a test would need to fake).
@MainActor
protocol LockScreenViewControllerDelegate: AnyObject {
  func lockScreenViewControllerDidRequestUnlock(_ controller: LockScreenViewController)
}

/// The 851-2422 lock screen: matches Apple Passwords' own lock screen — centered app icon with a
/// Touch ID badge, "<app name> is locked", "Touch ID or enter your password to continue.", and a
/// "Use Password…" button. `MainWindowController` swaps this in for `splitViewController` as
/// `window.contentViewController` while `LockCoordinator.state` is `.locked`, and hides/disables
/// the toolbar for the same duration — see that type.
@MainActor
final class LockScreenViewController: NSViewController {
  weak var delegate: LockScreenViewControllerDelegate?

  private let unlockFailureMessageField = NSTextField(wrappingLabelWithString: "")

  override func loadView() {
    view = NSView()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    configureSubviews()
  }

  private func configureSubviews() {
    let iconView = NSImageView()
    iconView.image = NSApplication.shared.applicationIconImage
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.translatesAutoresizingMaskIntoConstraints = false

    // The small circular Touch ID badge overlapping the icon's bottom-right corner, matching
    // Apple Passwords' own lock screen exactly (see the reference screenshots this ticket
    // shipped with). There's no system-provided "app icon + Touch ID badge" composite, so this
    // draws the badge itself: a plain white (light) / secondary-system-fill (dark) circle behind
    // an SF Symbol fingerprint glyph.
    let badgeBackground = NSView()
    badgeBackground.translatesAutoresizingMaskIntoConstraints = false
    badgeBackground.wantsLayer = true
    badgeBackground.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    badgeBackground.layer?.cornerRadius = 28
    badgeBackground.layer?.shadowColor = NSColor.black.cgColor
    badgeBackground.layer?.shadowOpacity = 0.2
    badgeBackground.layer?.shadowRadius = 3
    badgeBackground.layer?.shadowOffset = CGSize(width: 0, height: -1)

    let badgeImageView = NSImageView()
    badgeImageView.image = NSImage(
      systemSymbolName: "touchid",
      accessibilityDescription: "Touch ID"
    )
    badgeImageView.symbolConfiguration = .init(pointSize: 30, weight: .regular)
    badgeImageView.contentTintColor = .secondaryLabelColor
    badgeImageView.translatesAutoresizingMaskIntoConstraints = false

    let iconContainer = NSView()
    iconContainer.translatesAutoresizingMaskIntoConstraints = false
    iconContainer.addSubview(iconView)
    iconContainer.addSubview(badgeBackground)
    badgeBackground.addSubview(badgeImageView)

    let titleField = NSTextField(labelWithString: "\(LilPasswordsKit.productName) is locked")
    titleField.font = .systemFont(ofSize: 22, weight: .bold)
    titleField.alignment = .center
    titleField.translatesAutoresizingMaskIntoConstraints = false

    let subtitleField = NSTextField(labelWithString: "Touch ID or enter your password to continue.")
    subtitleField.font = .systemFont(ofSize: 14)
    subtitleField.textColor = .secondaryLabelColor
    subtitleField.alignment = .center
    subtitleField.translatesAutoresizingMaskIntoConstraints = false

    unlockFailureMessageField.font = .systemFont(ofSize: 12)
    unlockFailureMessageField.textColor = .systemRed
    unlockFailureMessageField.alignment = .center
    unlockFailureMessageField.maximumNumberOfLines = 2
    unlockFailureMessageField.translatesAutoresizingMaskIntoConstraints = false
    unlockFailureMessageField.isHidden = true

    let passwordButton = NSButton(title: "Use Password…", target: self, action: #selector(unlockTapped))
    passwordButton.bezelStyle = .rounded
    passwordButton.controlSize = .large
    passwordButton.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView(views: [
      iconContainer, titleField, subtitleField, unlockFailureMessageField, passwordButton,
    ])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 8
    stack.setCustomSpacing(20, after: iconContainer)
    stack.setCustomSpacing(4, after: titleField)
    stack.setCustomSpacing(20, after: subtitleField)
    stack.translatesAutoresizingMaskIntoConstraints = false

    view.addSubview(stack)

    NSLayoutConstraint.activate([
      iconContainer.widthAnchor.constraint(equalToConstant: 128),
      iconContainer.heightAnchor.constraint(equalToConstant: 128),
      iconView.widthAnchor.constraint(equalToConstant: 128),
      iconView.heightAnchor.constraint(equalToConstant: 128),
      iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),

      badgeBackground.widthAnchor.constraint(equalToConstant: 56),
      badgeBackground.heightAnchor.constraint(equalToConstant: 56),
      badgeBackground.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 4),
      badgeBackground.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: 4),

      badgeImageView.centerXAnchor.constraint(equalTo: badgeBackground.centerXAnchor),
      badgeImageView.centerYAnchor.constraint(equalTo: badgeBackground.centerYAnchor),

      passwordButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),

      stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -80),
    ])
  }

  /// Shown under the subtitle when a prior `unlock()` attempt failed
  /// (`LockState.unlockFailed(message:)`) — `MainWindowController` calls this after every state
  /// change, clearing it (`message: nil`) once the state moves away from `.unlockFailed`.
  func setUnlockFailureMessage(_ message: String?) {
    unlockFailureMessageField.stringValue = message ?? ""
    unlockFailureMessageField.isHidden = message == nil
  }

  @objc
  private func unlockTapped() {
    delegate?.lockScreenViewControllerDidRequestUnlock(self)
  }
}
