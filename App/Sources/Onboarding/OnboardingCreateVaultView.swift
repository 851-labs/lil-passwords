import LilPasswordsKit
import SwiftUI

/// Drives step 2's "Create Your Vault" button: calls the same `LockCoordinator.setUpVault()`
/// every non-onboarding first run already used (`MainWindowController`'s old, direct
/// `startFirstRunVaultSetupIfNeeded()` path) — nothing about vault creation itself is
/// reimplemented here, only who calls it and when.
@MainActor
final class OnboardingCreateVaultViewModel: ObservableObject {
  @Published private(set) var isCreating = false
  @Published private(set) var errorMessage: String?

  private let lockCoordinator: LockCoordinator

  /// Called with the helper's one-time recovery-key display string once `setUpVault()` succeeds —
  /// `OnboardingWindowController` reconstructs the structured `VaultCrypto.RecoveryKey` from it and
  /// hands off to the existing `RecoveryKitFlow`, exactly like `MainWindowController.presentRecoveryKit`
  /// does for the non-onboarding path.
  var onVaultCreated: (String) -> Void = { _ in }

  init(lockCoordinator: LockCoordinator) {
    self.lockCoordinator = lockCoordinator
  }

  func createVault() {
    guard !isCreating else { return }
    isCreating = true
    errorMessage = nil

    Task {
      do {
        let recoveryKeyDisplayString = try await lockCoordinator.setUpVault()
        isCreating = false
        onVaultCreated(recoveryKeyDisplayString)
      } catch {
        isCreating = false
        errorMessage = String(localized: "Couldn't create your vault: \(error.localizedDescription)")
      }
    }
  }
}

/// Onboarding step 2 (851-2439): creates the vault, then hands off to the existing recovery kit
/// save/confirm sheet — this step's own UI never shows the recovery key itself.
struct OnboardingCreateVaultView: View {
  @ObservedObject var viewModel: OnboardingCreateVaultViewModel

  var body: some View {
    OnboardingPageView(
      icon: .symbol(name: "key.fill", tint: .blue),
      title: String(localized: "Create Your Vault"),
      subtitle:
        String(
          localized: "Your passwords are encrypted and stored only on this Mac, unlocked with Touch ID or your "
        )
        + String(localized: "password. Next, we'll show you a one-time recovery key — keep it somewhere safe."),
      content: {
        if let errorMessage = viewModel.errorMessage {
          Text(errorMessage)
            .font(.system(size: 12))
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
      },
      primaryTitle: viewModel.errorMessage == nil ? String(localized: "Create Vault") : String(localized: "Try Again"),
      primaryAction: viewModel.createVault,
      isPrimaryLoading: viewModel.isCreating
    )
  }
}
