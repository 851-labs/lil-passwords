import AppKit
import LilPasswordsKit

/// Told when the user wants to authenticate. `MainWindowController` is the real conformer: it
/// owns the `LockCoordinator` this view controller has no reference to, keeping this file free of
/// any XPC/`LAContext` dependency so it stays a plain, static view (easy to screenshot for
/// tophat, and with nothing here that a test would need to fake).
@MainActor
protocol LockScreenViewControllerDelegate: AnyObject {
  func lockScreenViewControllerDidRequestUnlock(_ controller: LockScreenViewController)
  /// 851-2465: the user tapped "Try Again" after a helper-unreachable failure (see
  /// `LockScreenViewController.FailurePresentation`). `MainWindowController` re-runs
  /// `LockCoordinator.refresh()` — cheap, and re-checks connectivity without another `LAContext`
  /// prompt, which wouldn't help if the helper itself can't be reached.
  func lockScreenViewControllerDidRequestTryAgain(_ controller: LockScreenViewController)
  /// 851-2465: the user tapped "Open Login Items…", shown only when the helper-unreachable
  /// failure is because `LilPasswordsAgent` is registered but still awaiting approval in
  /// System Settings → General → Login Items & Extensions.
  func lockScreenViewControllerDidRequestOpenLoginItems(_ controller: LockScreenViewController)
}

/// The 851-2422 lock screen: matches Apple Passwords' own lock screen — centered app icon with a
/// Touch ID badge, "<app name> is locked", "Touch ID or enter your password to continue.", and a
/// "Use Password…" button. `MainWindowController` swaps this in for `splitViewController` as
/// `window.contentViewController` while `LockCoordinator.state` is `.locked`, and hides/disables
/// the toolbar for the same duration — see that type.
@MainActor
final class LockScreenViewController: NSViewController {
  /// A helper-unreachable (or other) unlock failure, already reduced to plain strings/bools by
  /// `MainWindowController` — this type deliberately knows nothing about `LilPasswordsKit`,
  /// `AgentClient`, or `HelperAgentRegistering` (see the type's own doc comment for why), so it
  /// stays a plain, easy-to-screenshot view with nothing here a test would need to fake.
  struct FailurePresentation {
    /// Shown under the subtitle, in red — e.g. "Couldn't reach lil passwords' background helper."
    let message: String
    /// Whether to show "Try Again" in place of "Use Password…" — true for a helper-unreachable
    /// failure, where retrying makes sense but authenticating again doesn't.
    let showsTryAgain: Bool
    /// An optional second line of smaller, secondary-colored guidance — the Login Items hint, or
    /// (DEBUG ad-hoc builds only) a pointer to docs/tophat.md.
    let hint: String?
    /// Whether to show "Open Login Items…" below the hint — true only when the helper-unreachable
    /// failure is because `LilPasswordsAgent` is registered but not yet approved.
    let showsOpenLoginItems: Bool
  }

  weak var delegate: LockScreenViewControllerDelegate?

  private let unlockFailureMessageField = NSTextField(wrappingLabelWithString: "")
  private let helperHintField = NSTextField(wrappingLabelWithString: "")
  private let passwordButton = NSButton(title: "Use Password…", target: nil, action: nil)
  private let tryAgainButton = NSButton(title: "Try Again", target: nil, action: nil)
  private let openLoginItemsButton = NSButton(title: "Open Login Items…", target: nil, action: nil)

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
    // draws the badge itself: a light circle behind a dark SF Symbol fingerprint glyph — a small
    // photoreal stand-in for a physical Touch ID sensor, so unlike the rest of this screen it's
    // deliberately *not* using dynamic/semantic colors that flip with the system appearance.
    //
    // This originally used `.windowBackgroundColor`/`.secondaryLabelColor` (both dynamic), which
    // inverted the badge to a dark circle with a light glyph in Dark Mode — the 851-2426 tophat
    // visual audit caught this as a contrast inversion versus Apple's badge, which stays
    // light-circle/dark-glyph in both appearances.
    let badgeBackground = NSView()
    badgeBackground.translatesAutoresizingMaskIntoConstraints = false
    badgeBackground.wantsLayer = true
    badgeBackground.layer?.backgroundColor = NSColor.white.cgColor
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
    badgeImageView.contentTintColor = NSColor.black.withAlphaComponent(0.85)
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

    // 851-2465: a second, smaller/secondary-colored line for the Login Items hint or (DEBUG
    // ad-hoc builds) the docs/tophat.md pointer — set by `applyFailurePresentation(_:)`, never
    // shown alongside `unlockFailureMessageField` being hidden.
    helperHintField.font = .systemFont(ofSize: 11)
    helperHintField.textColor = .secondaryLabelColor
    helperHintField.alignment = .center
    helperHintField.maximumNumberOfLines = 3
    helperHintField.translatesAutoresizingMaskIntoConstraints = false
    helperHintField.isHidden = true

    passwordButton.target = self
    passwordButton.action = #selector(unlockTapped)
    passwordButton.bezelStyle = .rounded
    passwordButton.controlSize = .large
    passwordButton.translatesAutoresizingMaskIntoConstraints = false

    // 851-2465: shown instead of `passwordButton` when the failure is helper-unreachable —
    // authenticating again can't help if the helper itself can't be reached, but re-checking
    // connectivity (via `LockCoordinator.refresh()`) can.
    tryAgainButton.target = self
    tryAgainButton.action = #selector(tryAgainTapped)
    tryAgainButton.bezelStyle = .rounded
    tryAgainButton.controlSize = .large
    tryAgainButton.translatesAutoresizingMaskIntoConstraints = false
    tryAgainButton.isHidden = true

    // 851-2465: shown under the hint only when the helper-unreachable failure is specifically an
    // unapproved Login Item — opens straight to System Settings → General → Login Items &
    // Extensions, the same destination `AppDelegate`'s first-launch approval sheet uses.
    openLoginItemsButton.target = self
    openLoginItemsButton.action = #selector(openLoginItemsTapped)
    openLoginItemsButton.bezelStyle = .rounded
    openLoginItemsButton.controlSize = .regular
    openLoginItemsButton.translatesAutoresizingMaskIntoConstraints = false
    openLoginItemsButton.isHidden = true

    let stack = NSStackView(views: [
      iconContainer, titleField, subtitleField, unlockFailureMessageField, helperHintField,
      tryAgainButton, openLoginItemsButton, passwordButton,
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
      tryAgainButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),

      stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -80),
    ])
  }

  /// Renders (or clears, passing `nil`) a prior unlock failure — `MainWindowController` calls
  /// this after every `LockState` change, passing `nil` once the state moves away from
  /// `.unlockFailed` (see `LockState.unlockFailed(_:)` and `UnlockFailure`, `LilPasswordsKit`).
  func applyFailurePresentation(_ presentation: FailurePresentation?) {
    guard let presentation else {
      unlockFailureMessageField.isHidden = true
      helperHintField.isHidden = true
      tryAgainButton.isHidden = true
      openLoginItemsButton.isHidden = true
      passwordButton.isHidden = false
      return
    }

    unlockFailureMessageField.stringValue = presentation.message
    unlockFailureMessageField.isHidden = false

    helperHintField.stringValue = presentation.hint ?? ""
    helperHintField.isHidden = presentation.hint == nil

    tryAgainButton.isHidden = !presentation.showsTryAgain
    openLoginItemsButton.isHidden = !presentation.showsOpenLoginItems
    // Authenticating again can't fix an unreachable helper — swap "Use Password…" out for "Try
    // Again" rather than showing both.
    passwordButton.isHidden = presentation.showsTryAgain
  }

  @objc
  private func unlockTapped() {
    delegate?.lockScreenViewControllerDidRequestUnlock(self)
  }

  @objc
  private func tryAgainTapped() {
    delegate?.lockScreenViewControllerDidRequestTryAgain(self)
  }

  @objc
  private func openLoginItemsTapped() {
    delegate?.lockScreenViewControllerDidRequestOpenLoginItems(self)
  }
}
