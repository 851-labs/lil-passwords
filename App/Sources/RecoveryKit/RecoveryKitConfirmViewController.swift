import AppKit
import LilPasswordsKit

/// Step two of `RecoveryKitSheetController`: proves the user actually saved their recovery key by
/// asking them to retype its last group of characters, rather than just trusting a "yes, I saved
/// it" checkbox.
@MainActor
final class RecoveryKitConfirmViewController: NSViewController {
  /// Called once the typed group matches.
  var onConfirmed: (() -> Void)?
  /// Called when the user wants to go back and look at the key again.
  var onBack: (() -> Void)?

  private let appName: String
  private let recoveryKey: VaultCrypto.RecoveryKey

  private var lastGroupField: NSTextField!
  private var errorLabel: NSTextField!
  private var confirmButton: NSButton!

  private var expectedLastGroup: String {
    recoveryKey.displayString.split(separator: "-").last.map(String.init) ?? ""
  }

  init(appName: String, recoveryKey: VaultCrypto.RecoveryKey) {
    self.appName = appName
    self.recoveryKey = recoveryKey
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func loadView() {
    let titleField = NSTextField(labelWithString: String(localized: "Confirm You Saved It"))
    titleField.font = .boldSystemFont(ofSize: 15)

    let subtitleField = NSTextField(
      wrappingLabelWithString: String(
        localized: """
          To make sure you saved your \(appName) recovery key correctly, type its last group of \
          characters below.
          """
      )
    )
    subtitleField.font = .systemFont(ofSize: 12)
    subtitleField.textColor = .secondaryLabelColor

    let field = NSTextField()
    field.placeholderString = String(localized: "Last group")
    field.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
    field.alignment = .center
    field.delegate = self
    field.target = self
    field.action = #selector(confirmTapped)
    lastGroupField = field

    let error = NSTextField(labelWithString: "")
    error.font = .systemFont(ofSize: 11)
    error.textColor = .systemRed
    error.isHidden = true
    errorLabel = error

    let backButton = NSButton(title: String(localized: "Back"), target: self, action: #selector(backTapped))
    let confirm = NSButton(title: String(localized: "Confirm"), target: self, action: #selector(confirmTapped))
    confirm.keyEquivalent = "\r"
    // Same fix as `ImportPreviewViewController.importButton` (851-2426 tophat visual audit):
    // `keyEquivalent = "\r"` alone doesn't reliably paint this blue in a custom sheet.
    confirm.bezelColor = .controlAccentColor
    confirm.isEnabled = false
    confirmButton = confirm

    let spacer = NSView()
    spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    let footerRow = NSStackView(views: [backButton, spacer, confirm])
    footerRow.orientation = .horizontal

    let stack = NSStackView(views: [titleField, subtitleField, field, error, footerRow])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    stack.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      subtitleField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
      field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
      footerRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
    ])

    view = container
    preferredContentSize = NSSize(width: 420, height: 250)
  }

  @objc
  private func backTapped() {
    onBack?()
  }

  @objc
  private func confirmTapped() {
    let typed = normalized(lastGroupField.stringValue)
    guard !typed.isEmpty else { return }
    guard typed == normalized(expectedLastGroup) else {
      errorLabel.stringValue = String(localized: "That doesn't match the last group of your recovery key. Try again.")
      errorLabel.isHidden = false
      return
    }
    onConfirmed?()
  }

  private func normalized(_ string: String) -> String {
    string.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
  }
}

extension RecoveryKitConfirmViewController: NSTextFieldDelegate {
  func controlTextDidChange(_ notification: Notification) {
    errorLabel.isHidden = true
    confirmButton.isEnabled = !lastGroupField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
