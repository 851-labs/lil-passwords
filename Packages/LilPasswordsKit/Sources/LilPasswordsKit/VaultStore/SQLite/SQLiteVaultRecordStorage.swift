import Foundation

/// `VaultRecordStorage`, backed by a SQLite database file: the `meta`, `records`, and `changes`
/// tables described in the ticket, plus a `schema_migrations` table and `PRAGMA user_version`
/// tracking which migrations have been applied (both together, deliberately: `user_version` is
/// what a future `sqlite3`/DB Browser session can check at a glance with no query, while
/// `schema_migrations` records *when* each version was applied, useful for support/debugging a
/// user's vault file).
final class SQLiteVaultRecordStorage: VaultRecordStorage {
  private let db: SQLiteDatabase
  private var didEnsureSchema = false

  init(databaseURL: URL) throws {
    try FileManager.default.createDirectory(
      at: databaseURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    db = try SQLiteDatabase(path: databaseURL.path)
  }

  // MARK: - Schema and migrations

  private struct Migration {
    let version: Int32
    let statements: [String]
  }

  /// Every migration this build knows how to apply, in order. Add new ones to the end; never
  /// edit an already-shipped entry, since a database created by an older build may already have
  /// applied it exactly as originally written.
  private static let migrations: [Migration] = [
    Migration(
      version: 1,
      statements: [
        """
        CREATE TABLE meta (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          vaultId TEXT NOT NULL,
          formatVersion INTEGER NOT NULL,
          wrappedKeyJSON BLOB NOT NULL,
          keyCheckJSON BLOB NOT NULL,
          createdAt REAL NOT NULL
        )
        """,
        """
        CREATE TABLE records (
          id TEXT PRIMARY KEY,
          type TEXT NOT NULL,
          version INTEGER NOT NULL,
          modifiedAt REAL NOT NULL,
          deviceId TEXT NOT NULL,
          deleted INTEGER NOT NULL,
          keyId TEXT NOT NULL,
          formatVersion INTEGER NOT NULL,
          sealed BLOB NOT NULL,
          schemaVersion INTEGER NOT NULL
        )
        """,
        """
        CREATE TABLE changes (
          seq INTEGER PRIMARY KEY AUTOINCREMENT,
          recordId TEXT NOT NULL,
          version INTEGER NOT NULL,
          at REAL NOT NULL
        )
        """,
        "CREATE INDEX changes_recordId ON changes(recordId)",
      ]
    )
  ]

  func ensureSchema() throws {
    guard !didEnsureSchema else { return }
    try db.execute(
      "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, appliedAt REAL NOT NULL)"
    )

    let appliedVersion = try currentMigrationVersion()
    for migration in Self.migrations where migration.version > appliedVersion {
      try db.withTransaction {
        for statement in migration.statements {
          try db.execute(statement)
        }
        let insert = try db.prepare("INSERT INTO schema_migrations (version, appliedAt) VALUES (?, ?)")
        insert.bind(Int64(migration.version), at: 1)
        insert.bind(Date().timeIntervalSince1970, at: 2)
        try insert.step()
      }
      try db.execute("PRAGMA user_version = \(migration.version)")
    }

    didEnsureSchema = true
  }

  private func currentMigrationVersion() throws -> Int32 {
    let statement = try db.prepare("SELECT COALESCE(MAX(version), 0) FROM schema_migrations")
    try statement.step()
    return Int32(statement.columnInt64(0))
  }

  // MARK: - Meta

  private static let jsonEncoder = JSONEncoder()
  private static let jsonDecoder = JSONDecoder()

  func loadMeta() throws -> VaultMetaRow? {
    try ensureSchema()
    let statement = try db.prepare(
      "SELECT vaultId, formatVersion, wrappedKeyJSON, keyCheckJSON, createdAt FROM meta WHERE id = 1"
    )
    guard try statement.step() else { return nil }

    guard let vaultId = UUID(uuidString: statement.columnText(0)) else {
      throw VaultStoreError.corruptData("meta.vaultId is not a valid UUID")
    }
    let wrappedKey = try Self.jsonDecoder.decode(VaultCrypto.WrappedKey.self, from: statement.columnData(2))
    let keyCheck = try Self.jsonDecoder.decode(VaultCrypto.SealedItem.self, from: statement.columnData(3))

    return VaultMetaRow(
      vaultId: vaultId,
      formatVersion: UInt8(statement.columnInt64(1)),
      wrappedKey: wrappedKey,
      keyCheck: keyCheck,
      createdAt: Date(timeIntervalSince1970: statement.columnDouble(4))
    )
  }

  func saveMeta(_ meta: VaultMetaRow) throws {
    try ensureSchema()
    let statement = try db.prepare(
      """
      INSERT INTO meta (id, vaultId, formatVersion, wrappedKeyJSON, keyCheckJSON, createdAt)
      VALUES (1, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        vaultId = excluded.vaultId,
        formatVersion = excluded.formatVersion,
        wrappedKeyJSON = excluded.wrappedKeyJSON,
        keyCheckJSON = excluded.keyCheckJSON,
        createdAt = excluded.createdAt
      """
    )
    statement.bind(meta.vaultId.uuidString, at: 1)
    statement.bind(Int64(meta.formatVersion), at: 2)
    statement.bind(try Self.jsonEncoder.encode(meta.wrappedKey), at: 3)
    statement.bind(try Self.jsonEncoder.encode(meta.keyCheck), at: 4)
    statement.bind(meta.createdAt.timeIntervalSince1970, at: 5)
    try statement.step()
  }

  // MARK: - Records

  private static let recordColumns =
    "id, type, version, modifiedAt, deviceId, deleted, keyId, formatVersion, sealed, schemaVersion"

  private func makeRecord(from statement: SQLiteStatement) throws -> VaultRecord {
    guard let id = UUID(uuidString: statement.columnText(0)) else {
      throw VaultStoreError.corruptData("records.id is not a valid UUID")
    }
    guard let type = VaultRecord.RecordType(rawValue: statement.columnText(1)) else {
      throw VaultStoreError.corruptData("records.type '\(statement.columnText(1))' is not recognized")
    }
    guard let deviceId = UUID(uuidString: statement.columnText(4)) else {
      throw VaultStoreError.corruptData("records.deviceId is not a valid UUID")
    }
    guard let keyId = UUID(uuidString: statement.columnText(6)) else {
      throw VaultStoreError.corruptData("records.keyId is not a valid UUID")
    }

    return VaultRecord(
      id: id,
      type: type,
      version: UInt64(bitPattern: statement.columnInt64(2)),
      modifiedAt: Date(timeIntervalSince1970: statement.columnDouble(3)),
      deviceId: deviceId,
      deleted: statement.columnInt64(5) != 0,
      sealed: VaultCrypto.SealedItem(
        keyId: keyId,
        combined: statement.columnData(8),
        formatVersion: UInt8(statement.columnInt64(7))
      ),
      schemaVersion: UInt32(statement.columnInt64(9))
    )
  }

  func loadAllRecords() throws -> [VaultRecord] {
    try ensureSchema()
    let statement = try db.prepare("SELECT \(Self.recordColumns) FROM records")
    var records: [VaultRecord] = []
    while try statement.step() {
      records.append(try makeRecord(from: statement))
    }
    return records
  }

  func loadRecord(id: UUID) throws -> VaultRecord? {
    try ensureSchema()
    let statement = try db.prepare("SELECT \(Self.recordColumns) FROM records WHERE id = ?")
    statement.bind(id.uuidString, at: 1)
    guard try statement.step() else { return nil }
    return try makeRecord(from: statement)
  }

  func upsertRecord(_ record: VaultRecord) throws {
    try ensureSchema()
    let statement = try db.prepare(
      """
      INSERT INTO records (\(Self.recordColumns))
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        type = excluded.type,
        version = excluded.version,
        modifiedAt = excluded.modifiedAt,
        deviceId = excluded.deviceId,
        deleted = excluded.deleted,
        keyId = excluded.keyId,
        formatVersion = excluded.formatVersion,
        sealed = excluded.sealed,
        schemaVersion = excluded.schemaVersion
      """
    )
    statement.bind(record.id.uuidString, at: 1)
    statement.bind(record.type.rawValue, at: 2)
    statement.bind(Int64(bitPattern: record.version), at: 3)
    statement.bind(record.modifiedAt.timeIntervalSince1970, at: 4)
    statement.bind(record.deviceId.uuidString, at: 5)
    statement.bind(record.deleted ? Int64(1) : Int64(0), at: 6)
    statement.bind(record.sealed.keyId.uuidString, at: 7)
    statement.bind(Int64(record.sealed.formatVersion), at: 8)
    statement.bind(record.sealed.combined, at: 9)
    statement.bind(Int64(record.schemaVersion), at: 10)
    try statement.step()
  }

  // MARK: - Change log

  func appendChangeLogEntry(recordId: UUID, version: UInt64, at date: Date) throws -> VaultChangeLogEntry {
    try ensureSchema()
    let statement = try db.prepare("INSERT INTO changes (recordId, version, at) VALUES (?, ?, ?)")
    statement.bind(recordId.uuidString, at: 1)
    statement.bind(Int64(bitPattern: version), at: 2)
    statement.bind(date.timeIntervalSince1970, at: 3)
    try statement.step()
    return VaultChangeLogEntry(seq: db.lastInsertRowID, recordId: recordId, version: version)
  }

  func changeLogEntries(since seq: Int64) throws -> [VaultChangeLogEntry] {
    try ensureSchema()
    let statement = try db.prepare("SELECT seq, recordId, version FROM changes WHERE seq > ? ORDER BY seq ASC")
    statement.bind(seq, at: 1)

    var entries: [VaultChangeLogEntry] = []
    while try statement.step() {
      guard let recordId = UUID(uuidString: statement.columnText(1)) else {
        throw VaultStoreError.corruptData("changes.recordId is not a valid UUID")
      }
      entries.append(
        VaultChangeLogEntry(
          seq: statement.columnInt64(0),
          recordId: recordId,
          version: UInt64(bitPattern: statement.columnInt64(2))
        )
      )
    }
    return entries
  }
}
