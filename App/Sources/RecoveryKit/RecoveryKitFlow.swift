import AppKit
import LilPasswordsKit

/// The small, stable entry points other features call to show the recovery kit and restore-vault
/// sheets. Kept in one file so onboarding (851-2439) has exactly two calls to make once it wires
/// vault creation into the real app flow — a real screen driving this doesn't exist yet, so
/// nothing in the shipped app calls these today; see `RecoveryKitDebugMenu` for how they're
/// exercised for now.
@MainActor
enum RecoveryKitFlow {
  /// Shows the "save your recovery key" sheet right after `VaultStoring.createVault()` returns
  /// its one-time `VaultCrypto.RecoveryKey`. `completion` receives `true` once the user has
  /// confirmed — by retyping the key's last group — that they saved it, or `false` if the sheet
  /// was dismissed without confirming. A caller that cares should treat `false` as "ask again
  /// later," not as a failure: the recovery key itself was already generated and wrapped into the
  /// vault by `createVault()` regardless of whether this sheet finishes.
  static func presentAfterVaultCreation(
    recoveryKey: VaultCrypto.RecoveryKey,
    appName: String = LilPasswordsKit.productName,
    over window: NSWindow,
    completion: @escaping (Bool) -> Void = { _ in }
  ) {
    RecoveryKitSheetController.present(recoveryKey: recoveryKey, appName: appName, from: window, completion: completion)
  }

  /// Shows the "restore from recovery key" sheet — onboarding's "I already have a vault" path,
  /// or a future Settings/menu action for restoring after a lost Keychain. This only calls
  /// `VaultStoring.restoreKey(recoveryKey:)`, never `open(with:)`; the caller decides whether and
  /// when to actually unlock with the `VaultCrypto.Key` it hands back on success.
  static func presentRestore(
    store: any VaultStoring,
    appName: String = LilPasswordsKit.productName,
    over window: NSWindow,
    completion: @escaping (RestoreVaultSheetController.Outcome) -> Void = { _ in }
  ) {
    RestoreVaultSheetController.present(store: store, appName: appName, from: window, completion: completion)
  }
}
