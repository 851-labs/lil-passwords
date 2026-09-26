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

  func lock() {
    vaultKey = nil
    decryptedItems.removeAll()
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
    for record in records where !record.deleted {
      items[record.id] = try RecordCodec.open(record, key: vaultKey)
    }
    decryptedItems = items
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

  // MARK: - Change log

  func changes(since seq: Int64) throws -> [VaultChangeLogEntry] {
    try storage.changeLogEntries(since: seq)
  }
}
