import Combine
import Foundation
import LilPasswordsKit

/// The app-side seam between the UI and the vault.
///
/// UI code depends on this protocol rather than on a concrete store, so swapping what's behind
/// it — `VaultStoreViewModel` (backed by the real, async, actor-isolated `VaultStoring` from
/// 851-2404) today, and eventually one that talks to `LilPasswordsAgent` over XPC (851-2427) —
/// never touches call sites in `App/Sources/MainWindow`. Kept intentionally small and
/// synchronous-looking: enough for browsing, viewing, and editing items, with the async/actor
/// bridging (and its error handling) entirely the conforming type's problem.
@MainActor
protocol VaultViewModel: AnyObject {
  /// Every item currently in the vault, including ones in "Recently Deleted"
  /// (`PasswordItem.deletedAt != nil`) — filtering those out for a particular category is the
  /// caller's job, same as `VaultStoring.allItems()`. Order is not guaranteed to be stable or
  /// meaningful; sort for display as needed.
  var items: [PasswordItem] { get }

  /// Publishes the current `items`, and again every time it changes. New subscribers receive
  /// the current value immediately.
  var itemsPublisher: AnyPublisher<[PasswordItem], Never> { get }

  /// Inserts `item` if its `id` is new, or replaces the existing item with the same `id`
  /// otherwise. Conforming types bump `modifiedAt` to the current date as part of saving, so
  /// callers don't need to (and shouldn't rely on whatever `modifiedAt` they passed in).
  func save(_ item: PasswordItem)

  /// Moves the item with the given id to "Recently Deleted" (`PasswordItem.deletedAt` set to
  /// now) — the same user-facing soft delete as `VaultStoring.delete(id:)`, not a permanent,
  /// unrecoverable removal. Does nothing if no item has that id.
  func delete(_ id: UUID)
}
