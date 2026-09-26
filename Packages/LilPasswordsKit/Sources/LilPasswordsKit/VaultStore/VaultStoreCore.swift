import Foundation

/// The vault-lifecycle and CRUD logic shared by `VaultStore` and `InMemoryVaultStore`.
///
/// This is a plain, non-actor, non-thread-safe class: all of its methods are synchronous and
/// none of them suspend, so whichever actor owns an instance (calling into it only from its own
/// isolated methods) gets serialized access for free. Keeping the logic here, parameterized over
/// `VaultRecordStorage`, means the SQLite-backed store and the in-memory test/preview double
/// share one implementation of "what does create/update/delete/open actually do", rather than
/// two copies that could quietly drift apart.
final class VaultStoreCore {
  private let storage: any VaultRecordStorage
  private let deviceId: UUID

  /// The vault key currently held in memory, or `nil` if locked.
  private(set) var vaultKey: VaultCrypto.Key?

  /// The decrypted index kept while unlocked: every non-tombstoned record's plaintext, keyed by
  /// id. Rebuilt from `storage` on `open(with:)`/`createVault()` and on every externally-observed
  /// change; kept incrementally up to date by `create`/`update`/`delete` in between.
  private var decryptedItems: [UUID: PasswordItem] = [:]

  /// The passkey analog of `decryptedItems` (851-2442): every non-tombstoned `PasskeyItem`'s
  /// plaintext, keyed by id, including its `privateKeyPKCS8`. Lives only in this process's memory
  /// while unlocked — see `PasskeyItem`'s documentation for why that key must never leave here.
  private var decryptedPasskeys: [UUID: PasskeyItem] = [:]

  init(storage: any VaultRecordStorage, deviceId: UUID) {
    self.storage = storage
    self.deviceId = deviceId
  }

  var isUnlocked: Bool { vaultKey != nil }

  // MARK: - Vault lifecycle

  private static let keyCheckPlaintext = Data("com.851labs.lilpasswords.vault-key-check".utf8)

  private static func keyCheckAAD(vaultId: UUID) -> VaultCrypto.AAD {
    VaultCrypto.AAD(recordId: vaultId, type: "vault-key-check", schemaVersion: 0, version: 0)
  }

  private static let currentMetaFormatVersion: UInt8 = 1

  func createVault() throws -> VaultCrypto.RecoveryKey {
    try storage.ensureSchema()
    guard try storage.loadMeta() == nil else {
      throw VaultStoreError.vaultAlreadyExists
    }

    let key = VaultCrypto.Key.generate()
    let recoveryKey = VaultCrypto.RecoveryKey.generate()
    let wrappedKey = try VaultCrypto.wrapKey(key, recoveryKey: recoveryKey)
    let vaultId = UUID()
    let keyCheck = try VaultCrypto.seal(Self.keyCheckPlaintext, aad: Self.keyCheckAAD(vaultId: vaultId), key: key)

    try storage.saveMeta(
      VaultMetaRow(
        vaultId: vaultId,
        formatVersion: Self.currentMetaFormatVersion,
        wrappedKey: wrappedKey,
        keyCheck: keyCheck,
        createdAt: Date()
      )
    )

    vaultKey = key
    try reloadIndex()
    return recoveryKey
  }

  func open(with key: VaultCrypto.Key) throws {
    try storage.ensureSchema()
    guard let meta = try storage.loadMeta() else {
      throw VaultStoreError.vaultNotFound
    }
    guard meta.formatVersion == Self.currentMetaFormatVersion else {
      throw VaultStoreError.unsupportedVaultFormatVersion(meta.formatVersion)
    }

    do {
      _ = try VaultCrypto.open(meta.keyCheck, aad: Self.keyCheckAAD(vaultId: meta.vaultId), key: key)
    } catch {
      throw VaultStoreError.incorrectKey
    }

    vaultKey = key
    try reloadIndex()
  }

  func restoreKey(recoveryKey: VaultCrypto.RecoveryKey) throws -> VaultCrypto.Key {
    try storage.ensureSchema()
    guard let meta = try storage.loadMeta() else {
      throw VaultStoreError.vaultNotFound
    }
    do {
      return try VaultCrypto.unwrapKey(meta.wrappedKey, recoveryKey: recoveryKey)
    } catch {
      throw VaultStoreError.incorrectKey
    }
  }

  func currentKey() throws -> VaultCrypto.Key {
    guard let vaultKey else { throw VaultStoreError.locked }
    return vaultKey
  }

  /// Generates a brand-new `VaultCrypto.RecoveryKey`, re-wraps the (unchanged) vault key under
  /// it, and atomically replaces the wrapped key stored in `meta`. No record is touched or
  /// re-sealed — the vault key itself never changes, only which recovery key can unwrap it — so
  /// this is much cheaper than the full vault-key rotation `docs/adr/0002-crypto.md` reserves as
  /// future work.
  ///
  /// The previous recovery key stops working the instant this returns: `saveMeta` overwrites the
  /// single `meta` row in place, so there's no way left to unwrap the vault key with it.
  ///
  /// Throws `VaultStoreError.locked` if the store isn't currently unlocked. Throws
  /// `VaultStoreError.vaultNotFound` if, somehow, there's no `meta` row despite `vaultKey` being
  /// set (shouldn't happen in practice — `open`/`createVault` are the only ways to set `vaultKey`,
  /// and both require a `meta` row to exist first).
  func rotateRecoveryKey() throws -> VaultCrypto.RecoveryKey {
    guard let vaultKey else { throw VaultStoreError.locked }
    guard var meta = try storage.loadMeta() else { throw VaultStoreError.vaultNotFound }

    let newRecoveryKey = VaultCrypto.RecoveryKey.generate()
    meta.wrappedKey = try VaultCrypto.wrapKey(vaultKey, recoveryKey: newRecoveryKey)
    try storage.saveMeta(meta)
    return newRecoveryKey
  }

  /// Whether this database already has a vault (`meta` row), regardless of lock state. Lets a
  /// caller (`AgentServer.status`) distinguish "no vault yet — first run" from "vault exists but
  /// is locked" without attempting (and failing) an `open(with:)` first.
  func vaultExists() throws -> Bool {
    try storage.ensureSchema()
    return try storage.loadMeta() != nil
  }

  func lock() {
    vaultKey = nil
    decryptedItems.removeAll()
    decryptedPasskeys.removeAll()
  }

  /// Re-derives `decryptedItems` from `storage` from scratch. Called after `open`/`createVault`,
  /// and again whenever this store learns of a change it didn't make itself (see
  /// `VaultStore.handleExternalChange`), so a write from another process is picked up here too.
  ///
  /// A record that fails to decrypt (wrong key — shouldn't happen once past the key-check above
  /// — or a tampered/corrupted row) fails this whole reload rather than silently omitting that
  /// one item, on the theory that a vault caught in a state it can't fully trust is safer to
  /// surface loudly than to quietly show a partial, possibly-stale view of.
  func reloadIndex() throws {
    guard let vaultKey else { return }
    let records = try storage.loadAllRecords()
    var items: [UUID: PasswordItem] = [:]
    var passkeys: [UUID: PasskeyItem] = [:]
    for record in records where !record.deleted {
      switch record.type {
      case .passwordItem:
        items[record.id] = try RecordCodec.open(record, key: vaultKey)
      case .passkeyItem:
        passkeys[record.id] = try PasskeyRecordCodec.open(record, key: vaultKey)
      }
    }
    decryptedItems = items
    decryptedPasskeys = passkeys
  }

  // MARK: - CRUD

  func create(_ item: PasswordItem) throws -> VaultChangeLogEntry {
    guard let vaultKey else { throw VaultStoreError.locked }
    guard try storage.loadRecord(id: item.id) == nil else {
      throw VaultStoreError.itemAlreadyExists(item.id)
    }

    let record = try RecordCodec.seal(item, version: 1, deviceId: deviceId, key: vaultKey)
    try storage.upsertRecord(record)
    decryptedItems[item.id] = item
    return try storage.appendChangeLogEntry(recordId: item.id, version: 1, at: record.modifiedAt)
  }

  func update(_ item: PasswordItem) throws -> VaultChangeLogEntry {
    guard let vaultKey else { throw VaultStoreError.locked }
    guard let existing = try storage.loadRecord(id: item.id) else {
      throw VaultStoreError.itemNotFound(item.id)
    }

    let nextVersion = existing.version + 1
    let record = try RecordCodec.seal(item, version: nextVersion, deviceId: deviceId, key: vaultKey)
    try storage.upsertRecord(record)
    decryptedItems[item.id] = item
    return try storage.appendChangeLogEntry(recordId: item.id, version: nextVersion, at: record.modifiedAt)
  }

  func delete(id: UUID) throws -> VaultChangeLogEntry {
    guard let vaultKey else { throw VaultStoreError.locked }
    guard let existing = try storage.loadRecord(id: id) else {
      throw VaultStoreError.itemNotFound(id)
    }

    var item = try RecordCodec.open(existing, key: vaultKey)
    item.deletedAt = item.deletedAt ?? Date()

    let nextVersion = existing.version + 1
    let record = try RecordCodec.seal(item, version: nextVersion, deviceId: deviceId, key: vaultKey)
    try storage.upsertRecord(record)
    decryptedItems[id] = item
    return try storage.appendChangeLogEntry(recordId: id, version: nextVersion, at: record.modifiedAt)
  }

  /// Un-deletes the item at `id`: clears `PasswordItem.deletedAt` and increments its revision,
  /// the same as any other write — the counterpart to `delete(id:)`.
  ///
  /// Throws `VaultStoreError.itemNotFound` if there's no row for `id`, including one that's
  /// already been permanently erased (`VaultRecord.deleted`), since there's nothing left to
  /// restore either way. Throws `VaultStoreError.locked` if the store isn't unlocked.
  func restore(id: UUID) throws -> VaultChangeLogEntry {
    guard let vaultKey else { throw VaultStoreError.locked }
    guard let existing = try storage.loadRecord(id: id), !existing.deleted else {
      throw VaultStoreError.itemNotFound(id)
    }

    var item = try RecordCodec.open(existing, key: vaultKey)
    item.deletedAt = nil

    let nextVersion = existing.version + 1
    let record = try RecordCodec.seal(item, version: nextVersion, deviceId: deviceId, key: vaultKey)
    try storage.upsertRecord(record)
    decryptedItems[id] = item
    return try storage.appendChangeLogEntry(recordId: id, version: nextVersion, at: record.modifiedAt)
  }

  /// Permanently erases the item at `id`: writes a `VaultRecord` tombstone (`deleted = true`)
  /// whose sealed payload has been wiped — there's no plaintext left to seal, so this doesn't go
  /// through `RecordCodec` at all — while still appending a change-log entry, so a future sync
  /// engine still learns `id` was deleted even though there's nothing left to sync about it.
  ///
  /// This is "Delete Permanently" from Recently Deleted, and is also what `purgeExpired(now:)`
  /// calls for each item it purges. Calling it directly on an item that was never soft-deleted is
  /// allowed; it just skips straight to the same permanent, unrecoverable outcome.
  ///
  /// `now` stamps the tombstone's `modifiedAt` and change-log entry; defaults to the wall clock
  /// but is overridable so `purgeExpired(now:)` can stamp every tombstone it writes with the same
  /// `now` it was given, rather than a fresh `Date()` per item.
  ///
  /// Throws `VaultStoreError.itemNotFound` if there's no row for `id`, including one already
  /// permanently deleted. Throws `VaultStoreError.locked` if the store isn't unlocked.
  func deletePermanently(id: UUID, now: Date = Date()) throws -> VaultChangeLogEntry {
    guard let vaultKey else { throw VaultStoreError.locked }
    guard let existing = try storage.loadRecord(id: id), !existing.deleted else {
      throw VaultStoreError.itemNotFound(id)
    }

    let nextVersion = existing.version + 1
    let tombstone = VaultRecord(
      id: id,
      type: existing.type,
      version: nextVersion,
      modifiedAt: now,
      deviceId: deviceId,
      deleted: true,
      sealed: VaultCrypto.SealedItem(keyId: vaultKey.id, combined: Data()),
      schemaVersion: existing.schemaVersion
    )
    try storage.upsertRecord(tombstone)
    decryptedItems.removeValue(forKey: id)
    decryptedPasskeys.removeValue(forKey: id)
    return try storage.appendChangeLogEntry(recordId: id, version: nextVersion, at: now)
  }

  /// Permanently erases every item whose `PasswordItem.deletedAt` is more than
  /// `PasswordItem.recentlyDeletedRetentionPeriod` in the past, as of `now` — the automatic
  /// 30-day purge. `now` is a parameter (rather than always `Date()`) so a real caller
  /// (`LilPasswordsAgent`, on a timer) and tests can both drive it deterministically instead of
  /// depending on the wall clock.
  ///
  /// Returns the ids that were purged (order not significant). Throws `VaultStoreError.locked`
  /// if the store isn't unlocked; never throws `VaultStoreError.itemNotFound`, since the ids it
  /// acts on come from the store's own up-to-date index.
  func purgeExpired(now: Date) throws -> [UUID] {
    guard vaultKey != nil else { throw VaultStoreError.locked }
    let expiredIds = decryptedItems.values.compactMap { item -> UUID? in
      guard let deletedAt = item.deletedAt else { return nil }
      return now.timeIntervalSince(deletedAt) > PasswordItem.recentlyDeletedRetentionPeriod ? item.id : nil
    }
    for id in expiredIds {
      _ = try deletePermanently(id: id, now: now)
    }
    return expiredIds
  }

  func item(id: UUID) throws -> PasswordItem? {
    guard vaultKey != nil else { throw VaultStoreError.locked }
    return decryptedItems[id]
  }

  func allItems() throws -> [PasswordItem] {
    guard vaultKey != nil else { throw VaultStoreError.locked }
    return Array(decryptedItems.values)
  }

  func items(matching query: String) throws -> [PasswordItem] {
    guard vaultKey != nil else { throw VaultStoreError.locked }
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return Array(decryptedItems.values) }

    return decryptedItems.values.filter { item in
      if item.title.lowercased().contains(needle) { return true }
      if item.usernames.contains(where: { $0.lowercased().contains(needle) }) { return true }
      if item.websites.contains(where: { ($0.host ?? $0.absoluteString).lowercased().contains(needle) }) {
        return true
      }
      return false
    }
  }

  // MARK: - Passkey CRUD (851-2442)

  /// Inserts `item` at revision 1. Throws `VaultStoreError.itemAlreadyExists` if `item.id`
  /// already has a row, or `VaultStoreError.locked` if the store isn't unlocked.
  ///
  /// There is no passkey counterpart to `create(_:)`'s sibling `restore(id:)`/soft-delete pair —
  /// unlike `PasswordItem`, `PasskeyItem` has no "Recently Deleted" stage (see the ticket:
  /// the detail card's one destructive action is a direct, permanent Delete), so
  /// `deletePasskeyPermanently(id:)` is the only removal path.
  func createPasskey(_ item: PasskeyItem) throws -> VaultChangeLogEntry {
    guard let vaultKey else { throw VaultStoreError.locked }
    guard try storage.loadRecord(id: item.id) == nil else {
      throw VaultStoreError.itemAlreadyExists(item.id)
    }

    let record = try PasskeyRecordCodec.seal(item, version: 1, deviceId: deviceId, key: vaultKey)
    try storage.upsertRecord(record)
    decryptedPasskeys[item.id] = item
    return try storage.appendChangeLogEntry(recordId: item.id, version: 1, at: record.modifiedAt)
  }

  /// Replaces the existing row for `item.id` with `item`, incrementing its revision — used after
  /// `passkeyAssert` updates `signCount`/`lastUsedAt`. Throws `VaultStoreError.itemNotFound` if
  /// there's no existing row, or `VaultStoreError.locked` if the store isn't unlocked.
  func updatePasskey(_ item: PasskeyItem) throws -> VaultChangeLogEntry {
    guard let vaultKey else { throw VaultStoreError.locked }
    guard let existing = try storage.loadRecord(id: item.id) else {
      throw VaultStoreError.itemNotFound(item.id)
    }

    let nextVersion = existing.version + 1
    let record = try PasskeyRecordCodec.seal(item, version: nextVersion, deviceId: deviceId, key: vaultKey)
    try storage.upsertRecord(record)
    decryptedPasskeys[item.id] = item
    return try storage.appendChangeLogEntry(recordId: item.id, version: nextVersion, at: record.modifiedAt)
  }

  /// Permanently erases the passkey at `id` — the Passkeys detail card's Delete button. Writes
  /// the same wiped-ciphertext `VaultRecord` tombstone `deletePermanently(id:)` writes for
  /// passwords, so it shares that method's implementation rather than duplicating it.
  ///
  /// Throws `VaultStoreError.itemNotFound` if there's no row for `id`, or
  /// `VaultStoreError.locked` if the store isn't unlocked.
  @discardableResult
  func deletePasskeyPermanently(id: UUID) throws -> VaultChangeLogEntry {
    try deletePermanently(id: id)
  }

  func passkey(id: UUID) throws -> PasskeyItem? {
    guard vaultKey != nil else { throw VaultStoreError.locked }
    return decryptedPasskeys[id]
  }

  func allPasskeys() throws -> [PasskeyItem] {
    guard vaultKey != nil else { throw VaultStoreError.locked }
    return Array(decryptedPasskeys.values)
  }

  // MARK: - Change log

  func changes(since seq: Int64) throws -> [VaultChangeLogEntry] {
    try storage.changeLogEntries(since: seq)
  }
}
