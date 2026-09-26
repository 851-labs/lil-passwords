import Foundation

/// The vault's single-row `meta` table: identity and key material that lets a vault be opened,
/// independent of any individual `PasswordItem`.
struct VaultMetaRow: Equatable {
  /// Identifies this vault (distinct from any individual vault key's `id`, so key rotation
  /// doesn't change it). Also doubles as `VaultCrypto.AAD.recordId` for the key-check canary.
  var vaultId: UUID

  /// The vault's own format version — distinct from `VaultCrypto.currentFormatVersion` (the
  /// sealing/wrapping wire format) and from the `schema_migrations`/`PRAGMA user_version` SQL
  /// schema version. This one versions the shape of `VaultMetaRow` itself, so a future change
  /// to what `meta` stores (e.g. adding device-approval key material) can be introduced without
  /// a flag day.
  var formatVersion: UInt8

  /// The vault key, wrapped under a key derived from the recovery key. `restoreKey(recoveryKey:)`
  /// unwraps this.
  var wrappedKey: VaultCrypto.WrappedKey

  /// A fixed plaintext sealed under the vault key at creation time, authenticated the same way
  /// any other record is. `open(with:)` re-seals nothing and re-derives nothing from this — it
  /// just tries to open it, so a wrong key fails fast with `VaultStoreError.incorrectKey`
  /// instead of only surfacing once the caller happens to decrypt a real record (or not at all,
  /// for a brand-new vault with zero records).
  var keyCheck: VaultCrypto.SealedItem

  var createdAt: Date
}

/// Abstracts "how records, meta, and the change log are actually stored" behind the CRUD/version
/// logic in `VaultStoreCore`, so that logic is written exactly once and shared between the real
/// `VaultStore` (backed by `SQLiteVaultRecordStorage`) and `InMemoryVaultStore` (backed by
/// `InMemoryVaultRecordStorage`, for tests and UI previews).
///
/// Not `Sendable` on purpose: every conformer here is a plain, non-thread-safe class, and every
/// caller (`VaultStoreCore`) is itself only ever driven from within the single actor that owns
/// it, which already serializes access. Nothing in this protocol is `public` — it's purely an
/// internal implementation seam.
protocol VaultRecordStorage: AnyObject {
  /// Creates the schema (tables, indexes) if this is a brand-new database, and runs any
  /// migrations a database created by an older build still needs. Safe to call repeatedly;
  /// implementations should make this a cheap no-op once the schema is current.
  func ensureSchema() throws

  func loadMeta() throws -> VaultMetaRow?
  func saveMeta(_ meta: VaultMetaRow) throws

  func loadAllRecords() throws -> [VaultRecord]
  func loadRecord(id: UUID) throws -> VaultRecord?
  /// Inserts `record`, or replaces the existing row with the same `id` if one exists.
  func upsertRecord(_ record: VaultRecord) throws

  /// Appends one entry to the change log and returns it with its assigned `seq`.
  func appendChangeLogEntry(recordId: UUID, version: UInt64, at date: Date) throws -> VaultChangeLogEntry
  func changeLogEntries(since seq: Int64) throws -> [VaultChangeLogEntry]
}
