import LilPasswordsKit

/// What the UI needs from the vault to save a new (or edited) item.
///
/// This is deliberately minimal — just `save(_:)` — because the real, fuller protocol (an
/// `items`/`itemsPublisher` cache, `delete(_:)`, etc.) belongs to 851-2415's item-detail work,
/// which isn't on `origin/main` yet as of this ticket (851-2416). Once 851-2415 merges its own
/// `VaultViewModel`, this file should be deleted in favor of that one rather than the two being
/// reconciled by hand.
@MainActor
protocol VaultViewModel {
  /// Persists `item`: creates it if its id isn't already in the vault, otherwise updates the
  /// existing row.
  func save(_ item: PasswordItem) async throws
}
