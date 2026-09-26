import AppKit
import LilPasswordsKit

@MainActor
protocol MenuBarLockedViewControllerDelegate: AnyObject {
  func menuBarLockedViewControllerDidRequestUnlock(_ controller: MenuBarLockedViewController)
}

/// The popover's locked state (851-2425): "<app name> is locked" plus an Unlock button, matching
/// Apple Passwords' own menu bar extra and mirroring `LockScreenViewController`'s wording/layout
/// at popover scale. Deliberately has no reference to `LockCoordinator`/XPC of its own —
/// `MenuBarRootViewController` owns the one shared `LockCoordinator` (851-2422/851-2425) and just
/// tells this view when to show a failure message, keeping this view easy to screenshot for
/// tophat and free of anything a test would need to fake.
@MainActor
final class MenuBarLockedViewController: NSViewController {
  weak var delegate: MenuBarLockedViewControllerDelegate?

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
    iconView.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
    iconView.symbolConfiguration = .init(pointSize: 40, weight: .regular)
    iconView.contentTintColor = .secondaryLabelColor
    iconView.translatesAutoresizingMaskIntoConstraints = false

    let titleField = NSTextField(labelWithString: String(localized: "\(LilPasswordsKit.productName) is locked"))
    titleField.font = .systemFont(ofSize: 15, weight: .semibold)
    titleField.alignment = .center
    titleField.translatesAutoresizingMaskIntoConstraints = false

    let subtitleField = NSTextField(
      labelWithString: String(localized: "Touch ID or enter your password to continue."))
    subtitleField.font = .systemFont(ofSize: 11)
    subtitleField.textColor = .secondaryLabelColor
    subtitleField.alignment = .center
    subtitleField.translatesAutoresizingMaskIntoConstraints = false

    unlockFailureMessageField.font = .systemFont(ofSize: 11)
    unlockFailureMessageField.textColor = .systemRed
    unlockFailureMessageField.alignment = .center
    unlockFailureMessageField.maximumNumberOfLines = 3
    unlockFailureMessageField.translatesAutoresizingMaskIntoConstraints = false
    unlockFailureMessageField.isHidden = true

    let unlockButton = NSButton(title: String(localized: "Unlock…"), target: self, action: #selector(unlockTapped))
    unlockButton.bezelStyle = .rounded
    unlockButton.controlSize = .regular
    unlockButton.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView(views: [iconView, titleField, subtitleField, unlockFailureMessageField, unlockButton])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 6
    stack.setCustomSpacing(14, after: iconView)
    stack.setCustomSpacing(2, after: titleField)
    stack.setCustomSpacing(16, after: subtitleField)
    stack.translatesAutoresizingMaskIntoConstraints = false

    view.addSubview(stack)
    NSLayoutConstraint.activate([
      unlockButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
      stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
    ])
  }

  /// Shown under the subtitle when a prior unlock attempt failed — `MenuBarRootViewController`
  /// calls this after every lock-state change, clearing it (`message: nil`) once the state moves
  /// away from `.unlockFailed`, same contract as `LockScreenViewController.setUnlockFailureMessage(_:)`.
  func setUnlockFailureMessage(_ message: String?) {
    unlockFailureMessageField.stringValue = message ?? ""
    unlockFailureMessageField.isHidden = message == nil
  }

  @objc
  private func unlockTapped() {
    delegate?.menuBarLockedViewControllerDidRequestUnlock(self)
  }
}
