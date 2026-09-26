import Foundation
import SQLite3

/// A thin, synchronous wrapper around one open connection to the system `sqlite3` C API —
/// reached via `import SQLite3`, which needs no dependency beyond linking `libsqlite3` (see
/// `Package.swift`). See `docs/adr/0003-vaultstore.md` for why this project uses the C API
/// directly instead of a wrapper library like GRDB.
///
/// Not thread-safe on its own — nothing here takes a lock. Every caller in this package
/// (`SQLiteVaultRecordStorage`, driven by the `VaultStore` actor) only ever touches a given
/// instance from within that actor's isolated methods, which already serializes access; this
/// class doesn't need to duplicate that guarantee.
final class SQLiteDatabase {
  private let handle: OpaquePointer

  init(path: String) throws {
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
    let rc = sqlite3_open_v2(path, &handle, flags, nil)
    guard rc == SQLITE_OK, let handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
      if let handle { sqlite3_close(handle) }
      throw VaultStoreError.sqlite(code: rc, message: message)
    }
    self.handle = handle
    // A brief automatic retry before failing with SQLITE_BUSY, so a lock held momentarily by
    // another process's writer (there's normally exactly one, per the storage ADR, but this
    // costs nothing and helps during tests that open several connections to the same file) does
    // not immediately surface as an error.
    sqlite3_busy_timeout(handle, 5000)
  }

  deinit {
    sqlite3_close(handle)
  }

  var lastErrorMessage: String {
    String(cString: sqlite3_errmsg(handle))
  }

  var lastInsertRowID: Int64 {
    sqlite3_last_insert_rowid(handle)
  }

  /// Runs `sql` directly, for statements with no parameters and no result rows (DDL, `PRAGMA`,
  /// transaction control). Use `prepare` for anything that binds values or reads rows.
  func execute(_ sql: String) throws {
    var errorMessage: UnsafeMutablePointer<Int8>?
    let rc = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
    if rc != SQLITE_OK {
      let message = errorMessage.map { String(cString: $0) } ?? "sqlite3_exec failed"
      sqlite3_free(errorMessage)
      throw VaultStoreError.sqlite(code: rc, message: message)
    }
  }

  func prepare(_ sql: String) throws -> SQLiteStatement {
    var statement: OpaquePointer?
    let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
    guard rc == SQLITE_OK, let statement else {
      throw VaultStoreError.sqlite(code: rc, message: lastErrorMessage)
    }
    return SQLiteStatement(handle: statement, database: self)
  }

  /// Runs `body` inside `BEGIN IMMEDIATE`/`COMMIT`, rolling back if it throws. `IMMEDIATE`
  /// (rather than the default deferred transaction) acquires the write lock up front, so a
  /// multi-statement migration or write can't fail partway through with `SQLITE_BUSY` after
  /// already having made some of its changes.
  func withTransaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let result = try body()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }
}
