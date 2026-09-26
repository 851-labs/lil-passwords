import AppKit
import LilPasswordsKit

/// The one "Delete Passkey" confirmation flow, shared by the list's Delete key/context menu
/// (``PasskeysListViewController``) and the detail card's Delete button (``PasskeyDetailViewController``)
/// so both call sites present identical copy and gate the same way. Same shape as
/// `DeletedViewController.confirmAndDeletePermanently(_:in:)`: a `.critical` `NSAlert`, the
/// destructive action as the first (default) button, "This can't be undone," and the actual delete
/// only runs on `.alertFirstButtonReturn`.
@MainActor
enum PasskeyDeleteConfirmation {
  /// Presents the confirmation sheet on `window`; if confirmed, runs `action` (expected to call
  /// through to ``PasskeysViewModel/delete(id:)``) and beeps if it throws — there's no separate
  /// error alert, matching how `WiFiDetailViewController.showQRCodeTapped()` handles a failed
  /// async action from a detail card.
  static func present(_ passkey: PasskeyMetadata, from window: NSWindow, action: @escaping () async throws -> Void) {
    let title = PasskeysViewModel.title(for: passkey)
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = String(localized: "Delete Passkey for “\(title)”?")
    alert.informativeText = String(
      localized: "This can't be undone. You may not be able to sign in to \(title) this way again.")
    alert.addButton(withTitle: String(localized: "Delete Passkey"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    alert.beginSheetModal(for: window) { response in
      guard response == .alertFirstButtonReturn else { return }
      Task {
        do {
          try await action()
        } catch {
          NSSound.beep()
        }
      }
    }
  }
}
