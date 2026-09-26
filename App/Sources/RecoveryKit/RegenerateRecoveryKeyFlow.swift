import AppKit
import LilPasswordsKit

/// The entry point for "Generate New Recovery Key…" (a row in Settings → Security, since PR #23's
/// grouped-forms Settings rewrite landed — see `SecuritySettingsViewController`): authenticate,
/// confirm that the current recovery key will stop working, ask the helper to rotate it, then
/// show the same "save your recovery key" sheet `RecoveryKitFlow` shows right after vault
/// creation.
///
/// Mirrors `ExportFlow`'s shape — authenticate before anything else is even visible, confirm the
/// consequence, then act — and, like `ExportFlow`, authenticates via `DeviceAuthenticating` (a
/// one-off sensitive action taken while already unlocked), not `VaultAuthenticating` (the
/// unlock/lock state-transition seam `LockCoordinator` uses instead).
///
/// Calls `agentClient` directly rather than going through `VaultAgentConnecting` (the narrower
/// seam `LockCoordinator` uses, swappable with `OfflineDemoAgent` in DEBUG): `AppDelegate
/// .applicationWillTerminate` already calls the concrete `agentClient.lock()` directly for the
/// same reason — this isn't a lock-state transition `LockCoordinator` needs to know about.
@MainActor
enum RegenerateRecoveryKeyFlow {
  /// The confirmation alert shown after authentication succeeds, before rotating anything. A
  /// static factory (rather than presenting it inline) so the DEBUG tophat capture can grab a
  /// screenshot of exactly this alert without driving a real `LAContext` prompt or actually
  /// rotating the recovery key.
  static func makeConfirmationAlert() -> NSAlert {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = String(localized: "Generate a New Recovery Key?")
    alert.informativeText = String(
      localized: """
        Your current recovery key will stop working immediately. Make sure you save the new one \
        somewhere safe — there's no way to see it again later.
        """
    )
    alert.addButton(withTitle: String(localized: "Generate New Key"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    return alert
  }

  /// Starts the regenerate flow, presenting sheets over `window`.
  static func present(
    agentClient: AgentClient,
    over window: NSWindow,
    deviceAuthenticator: DeviceAuthenticating = LAContextDeviceAuthenticator()
  ) {
    Task {
      do {
        try await deviceAuthenticator.authenticate(
          reason: String(localized: "authenticate to generate a new recovery key")
        )
      } catch {
        presentFailureAlert(
          message: String(localized: "Authentication failed, so no new recovery key was generated."),
          over: window
        )
        return
      }

      let confirmation = makeConfirmationAlert()
      confirmation.beginSheetModal(for: window) { response in
        guard response == .alertFirstButtonReturn else { return }
        rotateAndPresentKit(agentClient: agentClient, over: window)
      }
    }
  }

  private static func rotateAndPresentKit(agentClient: AgentClient, over window: NSWindow) {
    Task {
      do {
        let recoveryKeyDisplayString = try await agentClient.rotateRecoveryKey()
        // `AgentResponse.recoveryKeyRotated` only ever hands the app the recovery key's rendered
        // `displayString` — never the raw `VaultCrypto.RecoveryKey`/its entropy, so it never has
        // to cross XPC. `RecoveryKitFlow.presentAfterVaultCreation` wants the structured
        // `RecoveryKey` (it needs the raw entropy to render the PDF/QR code), so it's
        // reconstructed here from the same display string the helper generated it from — the same
        // round trip `MainWindowController.presentRecoveryKit` does after `.createVault`.
        guard let recoveryKey = VaultCrypto.RecoveryKey(displayString: recoveryKeyDisplayString) else {
          assertionFailure("helper returned a recovery key display string that doesn't round-trip")
          presentFailureAlert(message: String(localized: "Something went wrong generating the new key."), over: window)
          return
        }
        RecoveryKitFlow.presentAfterVaultCreation(recoveryKey: recoveryKey, over: window)
      } catch {
        presentFailureAlert(
          message: String(localized: "The new recovery key couldn't be generated: \(error)"), over: window
        )
      }
    }
  }

  private static func presentFailureAlert(message: String, over window: NSWindow) {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = String(localized: "Couldn't Generate a New Recovery Key")
    alert.informativeText = message
    alert.beginSheetModal(for: window)
  }
}
