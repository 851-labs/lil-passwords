import AppKit
import LilPasswordsKit

/// Presents the "restore from recovery key" sheet: a single text field for the recovery key, with
/// checksum validation (`VaultCrypto.RecoveryKey.validate(displayString:)`) and friendly errors
/// for both a malformed/mistyped key and a key that doesn't match the given `store`'s vault
/// (`VaultStoring.restoreKey(recoveryKey:)`).
@MainActor
final class RestoreVaultSheetController: NSWindowController {
  enum Outcome {
    /// The key validated and matched `store`'s vault; here's the recovered vault key.
    case restored(VaultCrypto.Key)
    /// The sheet was dismissed (Cancel, or the window closing) without restoring anything.
    case cancelled
  }

  private let store: any VaultStoring
  private var completion: ((Outcome) -> Void)?

  private var keyField: NSTextField!
  private var errorLabel: NSTextField!
  private var restoreButton: NSButton!
  private var progressIndicator: NSProgressIndicator!
  private var didFinish = false

  private init(store: any VaultStoring, appName: String) {
    self.store = store
    let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    window.title = String(localized: "Restore \(appName) Vault")
    super.init(window: window)
    buildContent(appName: appName)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Presents the sheet over `parentWindow`. `completion` fires exactly once, with `.cancelled`
  /// if the user backs out before a key is successfully restored.
  static func present(
    store: any VaultStoring,
    appName: String,
    from parentWindow: NSWindow,
    completion: @escaping (Outcome) -> Void
  ) {
    let controller = RestoreVaultSheetController(store: store, appName: appName)
    controller.completion = completion
    guard let sheetWindow = controller.window else {
      completion(.cancelled)
      return
    }
    // The sheet's completion handler is the only strong reference keeping `controller` (and
    // therefore its window) alive; `beginSheet` retains this closure for the sheet's lifetime.
    parentWindow.beginSheet(sheetWindow) { _ in
      withExtendedLifetime(controller) {}
    }
  }

  private func buildContent(appName: String) {
    let titleField = NSTextField(labelWithString: String(localized: "Restore Your Vault"))
    titleField.font = .boldSystemFont(ofSize: 15)

    let subtitleField = NSTextField(
      wrappingLabelWithString: String(
        localized: "Enter the recovery key you saved when you set up \(appName)."
      )
    )
    subtitleField.font = .systemFont(ofSize: 12)
    subtitleField.textColor = .secondaryLabelColor

    let field = NSTextField()
    field.placeholderString = String(localized: "XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX")
    field.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    field.delegate = self
    field.target = self
    field.action = #selector(restoreTapped)
    keyField = field

    let error = NSTextField(labelWithString: "")
    error.font = .systemFont(ofSize: 11)
    error.textColor = .systemRed
    error.maximumNumberOfLines = 2
    error.isHidden = true
    errorLabel = error

    let progress = NSProgressIndicator()
    progress.style = .spinning
    progress.controlSize = .small
    progress.isDisplayedWhenStopped = false
    progressIndicator = progress

    let cancelButton = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelTapped))
    let restore = NSButton(title: String(localized: "Restore"), target: self, action: #selector(restoreTapped))
    restore.keyEquivalent = "\r"
    // Same fix as `ImportPreviewViewController.importButton` (851-2426 tophat visual audit):
    // `keyEquivalent = "\r"` alone doesn't reliably paint this blue in a custom sheet.
    restore.bezelColor = .controlAccentColor
    restore.isEnabled = false
    restoreButton = restore

    let spacer = NSView()
    spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    let footerRow = NSStackView(views: [progress, cancelButton, spacer, restore])
    footerRow.orientation = .horizontal
    footerRow.spacing = 8

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

    window?.contentView = container
    window?.setContentSize(NSSize(width: 440, height: 250))
  }

  @objc
  private func cancelTapped() {
    finish(outcome: .cancelled)
  }

  @objc
  private func restoreTapped() {
    switch VaultCrypto.RecoveryKey.validate(displayString: keyField.stringValue) {
    case .failure(let error):
      show(error: message(for: error))
    case .success(let recoveryKey):
      restore(with: recoveryKey)
    }
  }

  private func restore(with recoveryKey: VaultCrypto.RecoveryKey) {
    setLoading(true)
    let store = self.store
    Task { [weak self] in
      do {
        let key = try await store.restoreKey(recoveryKey: recoveryKey)
        self?.setLoading(false)
        self?.finish(outcome: .restored(key))
      } catch VaultStoreError.incorrectKey {
        self?.setLoading(false)
        self?.show(
          error: String(localized: "This recovery key doesn't match this vault. Double-check each group and try again.")
        )
      } catch VaultStoreError.vaultNotFound {
        self?.setLoading(false)
        self?.show(error: String(localized: "No vault was found to restore."))
      } catch {
        self?.setLoading(false)
        self?.show(error: String(localized: "Something went wrong restoring this vault. Please try again."))
      }
    }
  }

  private func setLoading(_ loading: Bool) {
    keyField.isEnabled = !loading
    restoreButton.isEnabled = !loading && !keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if loading {
      progressIndicator.startAnimation(nil)
    } else {
      progressIndicator.stopAnimation(nil)
    }
  }

  private func message(for error: VaultCrypto.RecoveryKey.ValidationError) -> String {
    switch error {
    case .empty:
      return String(localized: "Enter your recovery key.")
    case .wrongLength:
      return String(localized: "That doesn't look like a full recovery key — check that you typed every group.")
    case .checksumMismatch:
      return String(localized: "One of the characters looks mistyped. Double-check each group and try again.")
    }
  }

  private func show(error message: String) {
    errorLabel.stringValue = message
    errorLabel.isHidden = false
  }

  private func finish(outcome: Outcome) {
    guard let window, !didFinish else { return }
    didFinish = true
    if let sheetParent = window.sheetParent {
      sheetParent.endSheet(window)
    } else {
      window.close()
    }
    completion?(outcome)
  }
}

extension RestoreVaultSheetController: NSTextFieldDelegate {
  func controlTextDidChange(_ notification: Notification) {
    errorLabel.isHidden = true
    restoreButton.isEnabled = !keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
