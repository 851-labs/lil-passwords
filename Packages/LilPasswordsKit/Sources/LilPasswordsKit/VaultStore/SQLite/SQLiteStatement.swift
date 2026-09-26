import Foundation
import SQLite3

/// A prepared statement, bound and stepped with the raw `sqlite3_*` C API. Column and bind
/// indices below are 0-based for reads (`column*`) and 1-based for binds (`bind`), matching
/// `sqlite3`'s own convention for each.
final class SQLiteStatement {
  private let handle: OpaquePointer
  private unowned let database: SQLiteDatabase

  init(handle: OpaquePointer, database: SQLiteDatabase) {
    self.handle = handle
    self.database = database
  }

  deinit {
    sqlite3_finalize(handle)
  }

  // SQLITE_TRANSIENT, as a `sqlite3_destructor_type`: tells sqlite3 to copy the bytes we hand it
  // rather than assume they'll outlive the call, since the `String`/`Data` buffers below are
  // temporaries that Swift is free to deallocate right after the bind call returns.
  private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  func bind(_ value: Int64, at index: Int32) {
    sqlite3_bind_int64(handle, index, value)
  }

  func bind(_ value: Double, at index: Int32) {
    sqlite3_bind_double(handle, index, value)
  }

  func bind(_ value: String, at index: Int32) {
    sqlite3_bind_text(handle, index, value, -1, Self.transientDestructor)
  }

  func bind(_ value: Data, at index: Int32) {
    _ = value.withUnsafeBytes { buffer in
      sqlite3_bind_blob(handle, index, buffer.baseAddress, Int32(buffer.count), Self.transientDestructor)
    }
  }

  /// Steps the statement once. Returns `true` if it produced a row (`SQLITE_ROW`, so column
  /// accessors are valid), `false` once it's exhausted (`SQLITE_DONE`).
  @discardableResult
  func step() throws -> Bool {
    let rc = sqlite3_step(handle)
    switch rc {
    case SQLITE_ROW:
      return true
    case SQLITE_DONE:
      return false
    default:
      throw VaultStoreError.sqlite(code: rc, message: database.lastErrorMessage)
    }
  }

  func columnInt64(_ index: Int32) -> Int64 {
    sqlite3_column_int64(handle, index)
  }

  func columnDouble(_ index: Int32) -> Double {
    sqlite3_column_double(handle, index)
  }

  func columnText(_ index: Int32) -> String {
    guard let cString = sqlite3_column_text(handle, index) else { return "" }
    return String(cString: cString)
  }

  func columnData(_ index: Int32) -> Data {
    guard let bytes = sqlite3_column_blob(handle, index) else { return Data() }
    let count = Int(sqlite3_column_bytes(handle, index))
    return Data(bytes: bytes, count: count)
  }
}
