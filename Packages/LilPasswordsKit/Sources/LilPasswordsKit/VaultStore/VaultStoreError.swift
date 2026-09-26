import Foundation

/// Errors `VaultStore`/`InMemoryVaultStore` throw directly, as opposed to errors from
/// `VaultCrypto` or `RecordCodec` that are allowed to propagate unwrapped (e.g. a tampered
/// record surfaces as `VaultCrypto.Error.authenticationFailed`, not a `VaultStoreError` case) —
/// wrapping those would only throw away the specific failure a caller (or a test) might want to
/// match against.
public enum VaultStoreError: Swift.Error, Equatable, Sendable {
  /// `createVault()` was called against a database that already has a `meta` row.
  case vaultAlreadyExists

  /// `open(with:)` or `restoreKey(recoveryKey:)` was called before a vault was ever created at
  /// this database path — there is no `meta` row to read.
  case vaultNotFound

  /// A CRUD call was made while the store has no vault key in memory. Call `open(with:)` (or
  /// `createVault()`) first.
  case locked

  /// `open(with:)` was called with a key that doesn't match the vault's key-check canary in
  /// `meta` — almost always a bug in the caller (e.g. the wrong Keychain item), since the
  /// correct key is whatever `createVault()`/`currentKey()` originally handed back.
  case incorrectKey

  /// `create(_:)` was called with an item whose `id` already has a row in `records`. Use
  /// `update(_:)` to change an existing item.
  case itemAlreadyExists(UUID)

  /// `update(_:)` or `delete(id:)` was called with an id that has no row in `records`.
  case itemNotFound(UUID)

  /// The vault's `meta.formatVersion` is newer than this build understands.
  case unsupportedVaultFormatVersion(UInt8)

  /// A row read back from SQLite couldn't be reconstructed into a `VaultRecord`/`VaultMetaRow`
  /// (e.g. a column that's supposed to hold a UUID string doesn't parse as one). This indicates
  /// on-disk corruption unrelated to cryptographic tampering — `VaultCrypto`/`RecordCodec`
  /// errors cover the tampering case.
  case corruptData(String)

  /// A `sqlite3` C API call returned a non-`SQLITE_OK`/`SQLITE_ROW`/`SQLITE_DONE` result code.
  case sqlite(code: Int32, message: String)
}
