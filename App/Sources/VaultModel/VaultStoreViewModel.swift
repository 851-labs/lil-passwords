import Combine
import Foundation
import LilPasswordsKit

/// The `VaultViewModel` implementation backed by a real `VaultStoring` conformer (851-2404) —
/// `InMemoryVaultStore` today, since the app doesn't yet speak XPC to `LilPasswordsAgent`
/// (851-2427 lands the agent/XPC service itself; wiring the app up to it as a client, plus the
/// vault-unlock/Keychain flow that implies, is separate follow-up work). `InMemoryVaultStore` is
/// not a stand-in the way the old array-backed `VaultViewModel` was — per
/// `docs/adr/0003-vaultstore.md`, it shares its entire CRUD/version/change-log implementation
/// (`VaultStoreCore`) with the SQLite-backed `VaultStore`, so this class is exercising the same
/// real logic a persisted vault would.
///
/// `VaultStoring`'s methods are all `async` (its conformers are actors), while `VaultViewModel`
/// intentionally reads like a synchronous, always-current view for UI call sites. This type
/// bridges the two: `items`/`itemsPublisher` read from a cache kept fresh by looping over
/// `observeChanges()`, and `save`/`delete` fire off a `Task` and let that same observation loop
/// reconcile the cache once the write completes, rather than making call sites `await` anything.
@MainActor
final class VaultStoreViewModel: VaultViewModel {
  private let store: any VaultStoring
  private let subject = CurrentValueSubject<[PasswordItem], Never>([])
  private var observationTask: Task<Void, Never>?

  var items: [PasswordItem] { subject.value }

  var itemsPublisher: AnyPublisher<[PasswordItem], Never> {
    subject.eraseToAnyPublisher()
  }

  /// `seedItems` are written to the store as part of bootstrapping — only ever non-empty in
  /// DEBUG builds seeding sample data for previews/tophat/manual testing (see
  /// `SampleData.makeForCurrentLaunch()`).
  init(store: any VaultStoring = InMemoryVaultStore(), seedItems: [PasswordItem] = []) {
    self.store = store
    observationTask = Task { [weak self] in
      await self?.bootstrap(seedItems: seedItems)
    }
  }

  deinit {
    observationTask?.cancel()
  }

  /// Creates a fresh, ephemeral vault (a brand-new `InMemoryVaultStore` has none yet), seeds it,
  /// then loops forever reloading the cache every time `observeChanges()` says something may
  /// have changed — including the reload each seed write itself triggers.
  private func bootstrap(seedItems: [PasswordItem]) async {
    do {
      try await store.createVault()
      for item in seedItems {
        try await store.create(item)
      }
    } catch {
      assertionFailure("VaultStoreViewModel failed to initialize its vault: \(error)")
      return
    }
    await reload()
    for await _ in await store.observeChanges() {
      await reload()
    }
  }

  private func reload() async {
    guard let current = try? await store.allItems() else { return }
    subject.value = current
  }

  func save(_ item: PasswordItem) {
    var item = item
    item.modifiedAt = Date()
    Task {
      do {
        if try await store.item(id: item.id) != nil {
          try await store.update(item)
        } else {
          try await store.create(item)
        }
      } catch {
        assertionFailure("VaultStoreViewModel failed to save \(item.id): \(error)")
      }
    }
  }

  /// Soft-deletes through `VaultStoring.delete(id:)` — the real "move to Recently Deleted", not
  /// a hard removal (see `VaultViewModel.delete(_:)`'s documentation).
  func delete(_ id: UUID) {
    Task {
      do {
        try await store.delete(id: id)
      } catch {
        assertionFailure("VaultStoreViewModel failed to delete \(id): \(error)")
      }
    }
  }
}
