import Foundation

/// Seals and opens `PasskeyItem` ↔ `VaultRecord` using `VaultCrypto`.
///
/// The `PasskeyItem` analog of `RecordCodec` — see that type's documentation for the general
/// shape. Kept as a separate enum (rather than making `RecordCodec` generic) so each item type's
/// codec stays a simple, monomorphic pair of functions callers can reason about without generics,
/// matching how `PasswordItemSchema`/`PasskeyItemSchema` are also kept separate.
public enum PasskeyRecordCodec {
  public enum Error: Swift.Error, Equatable, Sendable {
    /// `open` was asked to decode a `schemaVersion` this build doesn't understand. See
    /// `PasskeyItemSchema`.
    case unsupportedSchemaVersion(UInt32)
  }

  /// Seals `item` into a `VaultRecord` at revision `version`, as written by `deviceId`.
  ///
  /// See `RecordCodec.seal` for why `version` is folded into the seal's authenticated data.
  public static func seal(
    _ item: PasskeyItem,
    version: UInt64,
    deviceId: UUID,
    modifiedAt: Date = Date(),
    deleted: Bool = false,
    key: VaultCrypto.Key
  ) throws -> VaultRecord {
    let schemaVersion = PasskeyItemSchema.currentVersion
    let plaintext = try PasskeyItemSchema.encodeCurrent(item)
    let aad = VaultCrypto.AAD(
      recordId: item.id,
      type: VaultRecord.RecordType.passkeyItem.rawValue,
      schemaVersion: schemaVersion,
      version: version
    )
    let sealed = try VaultCrypto.seal(plaintext, aad: aad, key: key)
    return VaultRecord(
      id: item.id,
      type: .passkeyItem,
      version: version,
      modifiedAt: modifiedAt,
      deviceId: deviceId,
      deleted: deleted,
      sealed: sealed,
      schemaVersion: schemaVersion
    )
  }

  /// Opens `record`, verifying it against `key` and reconstructing the exact `VaultCrypto.AAD` it
  /// was sealed with from the record's own plaintext fields, then decodes the resulting plaintext
  /// into a `PasskeyItem` (migrating forward if `record.schemaVersion` is older than current).
  ///
  /// Throws whatever `VaultCrypto.open` throws (wrong key, tampered ciphertext, or a replayed old
  /// `version`) or `Error.unsupportedSchemaVersion` if the record's schema is newer than this
  /// build understands.
  public static func open(_ record: VaultRecord, key: VaultCrypto.Key) throws -> PasskeyItem {
    let aad = VaultCrypto.AAD(
      recordId: record.id,
      type: record.type.rawValue,
      schemaVersion: record.schemaVersion,
      version: record.version
    )
    let plaintext = try VaultCrypto.open(record.sealed, aad: aad, key: key)
    do {
      return try PasskeyItemSchema.decode(plaintext, schemaVersion: record.schemaVersion)
    } catch let error as PasskeyItemSchema.Error {
      switch error {
      case .unsupportedSchemaVersion(let version):
        throw Error.unsupportedSchemaVersion(version)
      }
    }
  }
}
