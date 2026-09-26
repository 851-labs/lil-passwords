import Combine
import Foundation
import LilPasswordsKit

/// The app-side seam between the UI and the vault.
///
/// `VaultStore` (851-2404, encrypted SQLite) and the XPC-connected helper that will front it
/// (851-2427) are both still in progress, so UI code depends on this protocol rather than on
/// either concrete implementation. Once the real store lands, only its conformance needs to
/// change — call sites in `App/Sources/MainWindow` stay the same. Kept intentionally small:
/// enough for browsing, viewing, and editing items, and nothing that leans on persistence
/// details (transactions, migrations, sync) no one has settled on yet.
@MainActor
protocol VaultViewModel: AnyObject {
  /// Every item currently in the vault. Order is not guaranteed to be stable or meaningful;
  /// sort for display as needed.
  var items: [PasswordItem] { get }

  /// Publishes the current `items`, and again every time it changes. New subscribers receive
  /// the current value immediately.
  var itemsPublisher: AnyPublisher<[PasswordItem], Never> { get }

  /// Inserts `item` if its `id` is new, or replaces the existing item with the same `id`
  /// otherwise. Conforming types bump `modifiedAt` to the current date as part of saving, so
  /// callers don't need to (and shouldn't rely on whatever `modifiedAt` they passed in).
  func save(_ item: PasswordItem)

  /// Removes the item with the given id. Does nothing if no item has that id.
  func delete(_ id: UUID)
}
