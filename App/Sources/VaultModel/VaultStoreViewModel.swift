import Foundation
import LilPasswordsKit

/// A `VaultViewModel` backed by a real `VaultStoring` actor.
///
/// Bootstraps its own throwaway `InMemoryVaultStore` and creates a vault in it the first time
/// it's used — there's no real, shared vault-store instance to hand this yet (that's
/// `LilPasswordsAgent`'s XPC surface, 851-2427, and the app-side plumbing to talk to it, neither
/// of which exists on `origin/main` as of this ticket). `MainWindowController`'s existing
/// `VaultSnapshotStore` is a separate, UI-only placeholder for sidebar counts, not a real
/// `VaultStoring`; this type doesn't touch it.
@MainActor
final class VaultStoreViewModel: VaultViewModel {
  private let store: any VaultStoring
  private let ready: Task<Void, Never>

  init(store: any VaultStoring = InMemoryVaultStore()) {
    self.store = store
    ready = Task {
      // Throws `.vaultAlreadyExists` for a store that was handed in already bootstrapped (e.g. by
      // a test); that's fine, there's just nothing for this to do in that case.
      try? await store.createVault()
    }
  }

  func save(_ item: PasswordItem) async throws {
    // Guards against a save racing the one-time bootstrap above, e.g. a sheet finishing (Cmd-N,
    // fill in the fields, hit Save) faster than the store finished creating its vault.
    _ = await ready.value
    if try await store.item(id: item.id) != nil {
      try await store.update(item)
    } else {
      try await store.create(item)
    }
  }
}
