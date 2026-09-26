import AppKit
import LilPasswordsKit

/// Presents the two-step "save your recovery key" sheet shown right after
/// `VaultStoring.createVault()`: reveal the key (PDF preview, Save/Print/Copy) — see
/// `RecoveryKitRevealViewController` — then confirm the user actually saved it by retyping its
/// last group — see `RecoveryKitConfirmViewController`. Swaps `window.contentViewController`
/// between the two steps rather than pushing separate sheets, so it reads as one flow, not two.
@MainActor
final class RecoveryKitSheetController: NSWindowController {
  private let appName: String
  private let recoveryKey: VaultCrypto.RecoveryKey
  private let pdfData: Data
  private var completion: ((Bool) -> Void)?

  private init(appName: String, recoveryKey: VaultCrypto.RecoveryKey) {
    self.appName = appName
    self.recoveryKey = recoveryKey
    self.pdfData = RecoveryKitDocument.renderPDF(
      RecoveryKitDocument.Content(appName: appName, displayKey: recoveryKey.displayString)
    )

    let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    window.title = String(localized: "\(appName) Recovery Kit")
    super.init(window: window)
    showReveal()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Presents the sheet over `parentWindow`. `completion` receives `true` once the user confirms
  /// they saved the key, `false` if the sheet is dismissed (e.g. the window is closed) before
  /// that happens.
  static func present(
    recoveryKey: VaultCrypto.RecoveryKey,
    appName: String,
    from parentWindow: NSWindow,
    completion: @escaping (Bool) -> Void
  ) {
    let controller = RecoveryKitSheetController(appName: appName, recoveryKey: recoveryKey)
    controller.completion = completion
    guard let sheetWindow = controller.window else {
      completion(false)
      return
    }
    // The sheet's completion handler is the only strong reference keeping `controller` (and
    // therefore its window) alive; `beginSheet` retains this closure for the sheet's lifetime.
    parentWindow.beginSheet(sheetWindow) { _ in
      withExtendedLifetime(controller) {}
    }
  }

  private func showReveal() {
    let reveal = RecoveryKitRevealViewController(appName: appName, recoveryKey: recoveryKey, pdfData: pdfData)
    reveal.onContinue = { [weak self] in self?.showConfirm() }
    window?.contentViewController = reveal
  }

  private func showConfirm() {
    let confirm = RecoveryKitConfirmViewController(appName: appName, recoveryKey: recoveryKey)
    confirm.onBack = { [weak self] in self?.showReveal() }
    confirm.onConfirmed = { [weak self] in self?.finish(saved: true) }
    window?.contentViewController = confirm
  }

  private func finish(saved: Bool) {
    guard let window else { return }
    if let sheetParent = window.sheetParent {
      sheetParent.endSheet(window)
    } else {
      window.close()
    }
    completion?(saved)
  }
}
