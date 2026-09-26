import Combine
import Foundation
import LilPasswordsKit

/// The app-side seam between UI (item list, detail, search) and `VaultStoring` (851-2404): every
/// UI surface is built against this protocol, not against `VaultStoring` directly, so it stays
/// usable in SwiftUI previews/tests without needing to know `VaultStoring`'s methods are
/// async/actor-isolated. ``VaultStoreViewModel`` is the only conformance today, wrapping whatever
/// `VaultStoring` the app is handed — currently an in-process `InMemoryVaultStore`, since the XPC
/// helper (851-2427) isn't ready to hand back a real `VaultStore` proxy yet; once it is, only the
/// store passed into ``VaultStoreViewModel/init(store:)`` changes, not anything above this seam.
///
/// Deliberately tiny: a snapshot of items, a change notification, and the two mutations the UI
/// currently needs to perform (saving an edit, deleting an item). Anything more specific
/// (filtering, sorting, searching) is derived by callers from ``items``, not pushed into this
/// protocol.
@MainActor
public protocol VaultViewModel: AnyObject {
  /// The current, complete set of items — including soft-deleted ones (`deletedAt != nil`).
  /// Callers filter this down (by sidebar category, search query, etc.) themselves.
  var items: [PasswordItem] { get }

  /// Fires whenever ``items`` changes, so observers can re-read it and refresh their UI.
  var itemsDidChange: AnyPublisher<Void, Never> { get }

  /// Inserts `item` if its `id` isn't already present, otherwise replaces the existing item with
  /// the same `id`.
  func save(_ item: PasswordItem)

  /// Moves `item` to "Recently Deleted" by setting its `deletedAt`, mirroring
  /// `VaultStoring.delete(id:)`'s soft delete — or, if it's already there, leaves it as-is.
  func delete(_ item: PasswordItem)

  /// Un-deletes `item` (the Deleted view's "Recover", 851-2420), mirroring
  /// `VaultStoring.restore(id:)`.
  func restore(_ item: PasswordItem)

  /// Permanently, unrecoverably erases `item` (the Deleted view's "Delete Permanently",
  /// 851-2420), mirroring `VaultStoring.deletePermanently(id:)`.
  func deletePermanently(_ item: PasswordItem)
}

/// The `VaultViewModel` that backs the whole app: an async, actor-isolated `VaultStoring` wrapped
/// up as a synchronous, `@MainActor` snapshot plus a Combine publisher, since AppKit's item list
/// (an `NSTableView` data source) needs to read `items` synchronously.
@MainActor
public final class VaultStoreViewModel: VaultViewModel {
  private let store: any VaultStoring

  public private(set) var items: [PasswordItem] = []

  private let itemsDidChangeSubject = PassthroughSubject<Void, Never>()
  public var itemsDidChange: AnyPublisher<Void, Never> {
    itemsDidChangeSubject.eraseToAnyPublisher()
  }

  private var observationTask: Task<Void, Never>?
  private var purgeTask: Task<Void, Never>?

  /// How often ``start(seeding:)`` re-runs `VaultStoring.purgeExpired(now:)` once it's already
  /// run it at launch — once a day, per 851-2420.
  private static let purgeInterval: Duration = .seconds(86_400)

  public init(store: any VaultStoring) {
    self.store = store
  }

  /// Creates a fresh vault on `store` (so it's unlocked and ready for CRUD) and starts observing
  /// it for changes, optionally seeding `seedItems` first. `MainWindowController.init()` isn't
  /// async, so this is meant to be kicked off from an unstructured `Task` right after this view
  /// model is constructed — ``items`` simply stays empty until it completes, the same as any
  /// other async load.
  public func start(seeding seedItems: [PasswordItem] = []) async {
    do {
      try await store.createVault()
      for item in seedItems {
        try await store.create(item)
      }
    } catch {
      assertionFailure("Failed to initialize the vault: \(error)")
    }

    await refresh()

    observationTask = Task { [weak self, store] in
      let changes = await store.observeChanges()
      for await _ in changes {
        await self?.refresh()
      }
    }

    // Recently Deleted's 30-day purge (851-2420): once right away at launch, then once a day for
    // as long as the app stays running. `Task.sleep` (rather than a repeating `Timer`) keeps this
    // cancellable the same way `observationTask` above is, from `isolated deinit`.
    purgeTask = Task { [weak self, store] in
      while !Task.isCancelled {
        try? await store.purgeExpired(now: Date())
        await self?.refresh()
        try? await Task.sleep(for: Self.purgeInterval)
      }
    }
  }

  public func save(_ item: PasswordItem) {
    Task {
      do {
        try await store.update(item)
      } catch VaultStoreError.itemNotFound {
        try? await store.create(item)
      } catch {
        assertionFailure("Failed to save item \(item.id): \(error)")
      }
    }
  }

  public func delete(_ item: PasswordItem) {
    Task {
      do {
        try await store.delete(id: item.id)
      } catch {
        assertionFailure("Failed to delete item \(item.id): \(error)")
      }
    }
  }

  public func restore(_ item: PasswordItem) {
    Task {
      do {
        try await store.restore(id: item.id)
      } catch {
        assertionFailure("Failed to restore item \(item.id): \(error)")
      }
    }
  }

  public func deletePermanently(_ item: PasswordItem) {
    Task {
      do {
        try await store.deletePermanently(id: item.id)
      } catch {
        assertionFailure("Failed to permanently delete item \(item.id): \(error)")
      }
    }
  }

  private func refresh() async {
    items = (try? await store.allItems()) ?? []
    itemsDidChangeSubject.send()
  }

  isolated deinit {
    observationTask?.cancel()
    purgeTask?.cancel()
  }
}
