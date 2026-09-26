import Foundation

/// The plain-library API `VaultStore` (SQLite-backed) and `InMemoryVaultStore` (tests/previews)
/// both implement.
///
/// This is deliberately just a Swift actor protocol with no knowledge of XPC, `LilPasswordsAgent`,
/// or the app — per the project's architecture, `LilPasswordsAgent` is the process that will own
/// the real `VaultStore` instance and serve it to the app/`lilpw` over XPC (851-2427), but that's
/// a transport concern layered on top of this, not something `VaultStore` itself should know
/// about.
///
/// Conformers are actors so every method is already isolated/serialized without any extra
/// locking, and every parameter/return type here is `Sendable` so calling across an actor (or,
/// later, across an XPC boundary) is straightforward.
public protocol VaultStoring: Actor {
  // MARK: - Vault lifecycle

  /// Creates a brand-new vault at this store's database: generates a fresh vault key and a
  /// recovery key, wraps the vault key under the recovery key and stores that wrapped copy
  /// (plus a key-check canary used by `open(with:)`) in `meta`, and leaves the store unlocked
  /// with the new key.
  ///
  /// The recovery key is returned here and nowhere else — it is never persisted in the clear,
  /// and there is no API to retrieve it again later. A caller that loses it before writing it
  /// down (or that only holds `currentKey()`'s raw vault key) still has a working vault; they've
  /// just lost their only "new Mac"/lost-Keychain recovery path until they rotate to a new one.
  ///
  /// Throws `VaultStoreError.vaultAlreadyExists` if this database already has a vault.
  @discardableResult
  func createVault() async throws -> VaultCrypto.RecoveryKey

  /// Unlocks an existing vault with an already-known vault key — e.g. one `LilPasswordsAgent`
  /// read back from the local Keychain, or one obtained from `restoreKey(recoveryKey:)`.
  ///
  /// Throws `VaultStoreError.vaultNotFound` if this database has no vault yet,
  /// `VaultStoreError.unsupportedVaultFormatVersion` if `meta` is newer than this build
  /// understands, or `VaultStoreError.incorrectKey` if `key` doesn't match the vault's
  /// key-check canary.
  func open(with key: VaultCrypto.Key) async throws

  /// Recovers the vault key from `recoveryKey` via the wrapped key stored in `meta`, without
  /// unlocking the store. Callers typically pass the result straight to `open(with:)`.
  ///
  /// Throws `VaultStoreError.vaultNotFound` if this database has no vault yet, or
  /// `VaultStoreError.incorrectKey` if `recoveryKey` doesn't unwrap the stored key.
  func restoreKey(recoveryKey: VaultCrypto.RecoveryKey) async throws -> VaultCrypto.Key

  /// The vault key currently held in memory. `createVault()` doesn't hand the raw key back the
  /// way it hands back the recovery key once, so a caller that needs to persist it somewhere
  /// (e.g. `LilPasswordsAgent` writing it to the Keychain right after creating the vault) reads
  /// it from here instead.
  ///
  /// Throws `VaultStoreError.locked` if the store isn't currently unlocked.
  func currentKey() async throws -> VaultCrypto.Key

  /// Drops the in-memory vault key and the decrypted item index. Every CRUD/search call throws
  /// `VaultStoreError.locked` until `open(with:)` (or `createVault()`) succeeds again.
  func lock() async

  /// Whether the store currently holds a vault key in memory.
  var isUnlocked: Bool { get async }

  // MARK: - CRUD

  /// Inserts `item` at revision 1. Throws `VaultStoreError.itemAlreadyExists` if `item.id`
  /// already has a row, or `VaultStoreError.locked` if the store isn't unlocked.
  func create(_ item: PasswordItem) async throws

  /// Replaces the existing row for `item.id` with `item`, incrementing its revision. Throws
  /// `VaultStoreError.itemNotFound` if there's no existing row, or `VaultStoreError.locked` if
  /// the store isn't unlocked.
  func update(_ item: PasswordItem) async throws

  /// Soft-deletes the item at `id`: sets its `PasswordItem.deletedAt` (if not already set) and
  /// increments its revision, the same as any other `update`. This is the user-facing "move to
  /// Recently Deleted" — it does not set `VaultRecord.deleted`, the sync-layer tombstone that
  /// purges content entirely; see `VaultRecord.deleted`'s documentation for how the two relate.
  ///
  /// Throws `VaultStoreError.itemNotFound` if there's no existing row, or
  /// `VaultStoreError.locked` if the store isn't unlocked.
  func delete(id: UUID) async throws

  /// The item at `id`, or `nil` if there's no row for it. Throws `VaultStoreError.locked` if the
  /// store isn't unlocked.
  func item(id: UUID) async throws -> PasswordItem?

  /// Every item in the vault, including ones in "Recently Deleted" (`deletedAt != nil`) — this
  /// is the low-level store, so filtering those out for a particular UI is the caller's job.
  /// Throws `VaultStoreError.locked` if the store isn't unlocked.
  func allItems() async throws -> [PasswordItem]

  /// Items whose title, usernames, or website hosts contain `query` (case-insensitive), searched
  /// over the decrypted in-memory index kept while unlocked — no per-call decryption. An empty
  /// (or all-whitespace) `query` returns every item, same as `allItems()`.
  ///
  /// Throws `VaultStoreError.locked` if the store isn't unlocked.
  func items(matching query: String) async throws -> [PasswordItem]

  // MARK: - Change log

  /// Every change-log entry with `seq` strictly greater than `seq`, oldest first. A future sync
  /// engine's cursor: pass the last `seq` you've already pushed/pulled to get only what's new.
  func changes(since seq: Int64) async throws -> [VaultChangeLogEntry]

  // MARK: - Change observation

  /// A stream that yields once after every local write and once more after this store notices a
  /// change made by another process (see `docs/adr/0001-storage-and-process-model.md`'s Darwin
  /// notification decision). Each element carries no payload — it means "something may have
  /// changed, re-fetch whatever you're showing", the same way the app is expected to react to
  /// the Darwin notification itself.
  ///
  /// Every call returns a fresh, independent stream; there is no limit on how many can be live
  /// at once. A subscriber that stops iterating (or lets the stream's `Task` get cancelled) is
  /// cleaned up automatically.
  func observeChanges() async -> AsyncStream<Void>
}
