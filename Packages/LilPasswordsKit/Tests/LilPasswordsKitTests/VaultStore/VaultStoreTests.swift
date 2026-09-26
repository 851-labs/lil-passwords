import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct VaultStoreSharedBehaviorTests {
  private func makeStore() throws -> VaultStore {
    let directory = try makeTempDirectory()
    return try VaultStore(
      databaseURL: directory.appendingPathComponent("vault.sqlite"),
      darwinNotificationName: uniqueDarwinNotificationName()
    )
  }

  @Test func lockedStateThrows() async throws {
    try await VaultStoringSharedBehavior.assertLockedStateThrows(makeStore())
  }

  @Test func crudLifecycle() async throws {
    try await VaultStoringSharedBehavior.assertCRUDLifecycle(makeStore())
  }

  @Test func search() async throws {
    try await VaultStoringSharedBehavior.assertSearch(makeStore())
  }

  @Test func restore() async throws {
    try await VaultStoringSharedBehavior.assertRestore(makeStore())
  }

  @Test func deletePermanently() async throws {
    try await VaultStoringSharedBehavior.assertDeletePermanently(makeStore())
  }

  @Test func purgeExpired() async throws {
    try await VaultStoringSharedBehavior.assertPurgeExpired(makeStore())
  }

  @Test func restoreAndDeletePermanentlyAndPurgeExpiredSignalChangeObservers() async throws {
    try await VaultStoringSharedBehavior.assertRestoreAndDeletePermanentlyAndPurgeExpiredSignalChangeObservers(
      makeStore()
    )
  }

  @Test func changeLogOrdering() async throws {
    try await VaultStoringSharedBehavior.assertChangeLogOrdering(makeStore())
  }

  @Test func localWritesSignalChangeObservers() async throws {
    try await VaultStoringSharedBehavior.assertLocalWritesSignalChangeObservers(makeStore())
  }
}

@Suite struct VaultStoreTests {
  private func makeDatabaseURL() throws -> URL {
    try makeTempDirectory().appendingPathComponent("vault.sqlite")
  }

  @Test func createVaultTwiceFails() async throws {
    let store = try VaultStore(databaseURL: makeDatabaseURL())
    _ = try await store.createVault()

    await #expect(throws: VaultStoreError.vaultAlreadyExists) {
      _ = try await store.createVault()
    }
  }

  @Test func openingAVaultThatDoesNotExistFails() async throws {
    let store = try VaultStore(databaseURL: makeDatabaseURL())

    await #expect(throws: VaultStoreError.vaultNotFound) {
      try await store.open(with: .generate())
    }
  }

  @Test func openFailsWithTheWrongKey() async throws {
    let store = try VaultStore(databaseURL: makeDatabaseURL())
    _ = try await store.createVault()
    await store.lock()

    await #expect(throws: VaultStoreError.incorrectKey) {
      try await store.open(with: .generate())
    }
  }

  @Test func restoreKeyRecoversTheVaultKeyAndCanReopenTheStore() async throws {
    let store = try VaultStore(databaseURL: makeDatabaseURL())
    let recoveryKey = try await store.createVault()
    let originalKey = try await store.currentKey()
    await store.lock()

    let restoredKey = try await store.restoreKey(recoveryKey: recoveryKey)
    #expect(restoredKey == originalKey)

    try await store.open(with: restoredKey)
    #expect(await store.isUnlocked)
  }

  @Test func restoreKeyFailsWithTheWrongRecoveryKey() async throws {
    let store = try VaultStore(databaseURL: makeDatabaseURL())
    _ = try await store.createVault()

    await #expect(throws: VaultStoreError.incorrectKey) {
      _ = try await store.restoreKey(recoveryKey: .generate())
    }
  }

  /// The ticket's headline persistence requirement: data written by one `VaultStore` instance is
  /// still there — correctly decrypted — after that instance is gone and a brand-new instance
  /// opens the same database file with the same key.
  @Test func dataPersistsAcrossReopeningTheSameDatabaseFile() async throws {
    let url = try makeDatabaseURL()
    let notificationName = uniqueDarwinNotificationName()

    var store: VaultStore? = try VaultStore(databaseURL: url, darwinNotificationName: notificationName)
    _ = try await store!.createVault()
    let key = try await store!.currentKey()

    let item = makeSamplePasswordItem(title: "Persisted")
    try await store!.create(item)
    store = nil

    let reopened = try VaultStore(databaseURL: url, darwinNotificationName: notificationName)
    try await reopened.open(with: key)

    let loaded = try await reopened.item(id: item.id)
    #expect(loaded == item)

    let changes = try await reopened.changes(since: 0)
    #expect(changes.count == 1)
    #expect(changes[0].recordId == item.id)
  }

  /// A row's `sealed` blob, corrupted directly at the SQLite level (simulating disk corruption or
  /// tampering by something with file access but not the vault key), must be caught rather than
  /// silently misread: `open(with:)` reloads the whole index eagerly and fails fast on any record
  /// that doesn't authenticate.
  @Test func openFailsWhenARecordHasBeenTamperedWith() async throws {
    let url = try makeDatabaseURL()
    let store = try VaultStore(databaseURL: url)
    _ = try await store.createVault()
    let key = try await store.currentKey()

    let item = makeSamplePasswordItem()
    try await store.create(item)
    await store.lock()

    let db = try SQLiteDatabase(path: url.path)
    let select = try db.prepare("SELECT sealed FROM records WHERE id = ?")
    select.bind(item.id.uuidString, at: 1)
    #expect(try select.step())
    var sealed = select.columnData(0)
    sealed[sealed.count - 1] ^= 0xFF

    let update = try db.prepare("UPDATE records SET sealed = ? WHERE id = ?")
    update.bind(sealed, at: 1)
    update.bind(item.id.uuidString, at: 2)
    try update.step()

    await #expect(throws: VaultCrypto.Error.authenticationFailed) {
      try await store.open(with: key)
    }
  }

  /// Two `VaultStore` instances, opened against the *same* database file at the same time,
  /// writing concurrently. This is the scenario `SQLiteDatabase.withTransaction`'s
  /// `BEGIN IMMEDIATE` and `sqlite3_busy_timeout` exist for: real file-level lock contention
  /// between two separate SQLite connections, not just in-process actor serialization.
  @Test func concurrentWritesFromTwoStoreInstancesToTheSameDatabaseAllPersist() async throws {
    let url = try makeDatabaseURL()
    let notificationName = uniqueDarwinNotificationName()

    let storeA = try VaultStore(databaseURL: url, darwinNotificationName: notificationName)
    _ = try await storeA.createVault()
    let key = try await storeA.currentKey()

    let storeB = try VaultStore(databaseURL: url, darwinNotificationName: notificationName)
    try await storeB.open(with: key)

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<10 {
        group.addTask { try await storeA.create(makeSamplePasswordItem(title: "A\(index)")) }
        group.addTask { try await storeB.create(makeSamplePasswordItem(title: "B\(index)")) }
      }
      try await group.waitForAll()
    }

    // Force a fresh read from disk rather than trusting either instance's own in-memory index,
    // which only reflects the writes *it* made until it's notified of the other's.
    await storeA.lock()
    try await storeA.open(with: key)

    let items = try await storeA.allItems()
    #expect(items.count == 20)

    let changes = try await storeA.changes(since: 0)
    #expect(changes.count == 20)
    #expect(Set(changes.map(\.seq)).count == 20)
  }

  @Test func aWriteInOneInstanceNotifiesAnotherInstanceObservingTheSameDatabase() async throws {
    let url = try makeDatabaseURL()
    let notificationName = uniqueDarwinNotificationName()

    let writer = try VaultStore(databaseURL: url, darwinNotificationName: notificationName)
    _ = try await writer.createVault()
    let key = try await writer.currentKey()

    let reader = try VaultStore(databaseURL: url, darwinNotificationName: notificationName)
    try await reader.open(with: key)

    let stream = await reader.observeChanges()
    async let readerSawChange = waitForFirstElement(of: stream)

    let item = makeSamplePasswordItem()
    try await writer.create(item)

    #expect(await readerSawChange)

    let items = try await reader.allItems()
    #expect(items.map(\.id) == [item.id])
  }

  @Test func defaultDatabaseURLPointsAtApplicationSupport() throws {
    let url = try VaultStore.defaultDatabaseURL()
    #expect(url.lastPathComponent == "vault.sqlite")
    #expect(url.deletingLastPathComponent().lastPathComponent == "lil passwords")
  }

  /// The vault lives in `~/Library/Application Support` — a location a malicious sandboxed app
  /// or another local user account could otherwise read from directly (no vault key needed to
  /// exfiltrate ciphertext, and ciphertext is still worth protecting from casual snooping/copying
  /// even though it's encrypted). Opening a store must lock the containing directory down to
  /// owner-only access and the database file itself to owner-only read/write.
  @Test func openingAStoreRestrictsDirectoryAndDatabaseFilePermissions() async throws {
    func posixPermissions(atPath path: String) throws -> Int {
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    let directory = try makeTempDirectory().appendingPathComponent("lil passwords", isDirectory: true)
    let url = directory.appendingPathComponent("vault.sqlite")

    // Loosen the directory's permissions first, so the assertions below only pass if `VaultStore`
    // actually tightens them back up rather than merely happening to inherit a strict default.
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)

    let store = try VaultStore(databaseURL: url)
    _ = try await store.createVault()

    #expect(try posixPermissions(atPath: directory.path) == 0o700)
    #expect(try posixPermissions(atPath: url.path) == 0o600)
  }

  /// `-wal`/`-shm` sidecar files this project doesn't currently create (no WAL mode; see
  /// `docs/adr/0003-vaultstore.md`) but could inherit from a database file created elsewhere, or
  /// from a future build that does turn WAL on, must not keep whatever permissions they showed up
  /// with.
  @Test func openingAStoreRestrictsPreExistingSidecarFilePermissions() throws {
    let url = try makeDatabaseURL()
    // `vault.sqlite` must exist for a `-wal`/`-shm` sidecar of it to make sense, so create an
    // empty placeholder before the sidecars, matching what a real WAL-mode database looks like.
    FileManager.default.createFile(atPath: url.path, contents: Data())
    for suffix in ["-wal", "-shm"] {
      FileManager.default.createFile(atPath: url.path + suffix, contents: Data())
      try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path + suffix)
    }

    _ = try VaultStore(databaseURL: url)

    for suffix in ["-wal", "-shm"] {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path + suffix)
      #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
  }

  /// `PRAGMA secure_delete = ON` makes SQLite overwrite a deleted row's bytes with zeroes
  /// in-place rather than just unlinking them from the b-tree and leaving the ciphertext sitting
  /// in a freed page until something else happens to reuse it — belt-and-suspenders for a file
  /// that, database-level permissions aside, holds every password this vault has ever had.
  ///
  /// `secure_delete` is a per-connection setting, not persisted in the database file (Apple's
  /// SQLite build defaults every *fresh* connection to `secure_delete = FAST`, which is a
  /// different, weaker setting than the `ON` this storage explicitly asks for) — so this checks
  /// the storage's own connection directly via its test-only `isSecureDeleteEnabled()`, rather
  /// than opening a second, independent connection to the same file and learning nothing about
  /// the first one's setting.
  @Test func openingAStoreEnablesSecureDelete() throws {
    let storage = try SQLiteVaultRecordStorage(databaseURL: try makeDatabaseURL())
    #expect(try storage.isSecureDeleteEnabled())
  }
}
