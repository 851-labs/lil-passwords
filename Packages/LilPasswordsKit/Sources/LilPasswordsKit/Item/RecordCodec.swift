import Foundation

/// Seals and opens `PasswordItem` ↔ `VaultRecord` using `VaultCrypto`.
///
/// This is the one place that knows how to turn a plaintext `PasswordItem` into the envelope
/// that's actually persisted, and back. `VaultStore` (a later ticket) is expected to call
/// `seal`/`open` per row rather than reimplementing this mapping.
public enum RecordCodec {
  public enum Error: Swift.Error, Equatable, Sendable {
    /// `open` was asked to decode a `schemaVersion` this build doesn't understand. See
    /// `PasswordItemSchema`.
    case unsupportedSchemaVersion(UInt32)
  }

  /// Seals `item` into a `VaultRecord` at revision `version`, as written by `deviceId`.
  ///
  /// The record's `version` is folded into the seal's authenticated data (`VaultCrypto.AAD.version`),
  /// so an attacker with write access to the vault (or, later, the sync server) can't take an
  /// old sealed revision of this row and replay it back over a newer one — the open on the
  /// other end would fail rather than silently resurrecting stale data. See "AAD includes the
  /// record version" in `docs/adr/0002-crypto.md`.
  ///
  /// - Parameters:
  ///   - item: The plaintext item to seal. Its `id` becomes the record's `id`.
  ///   - version: This revision's counter. Callers (`VaultStore`) are responsible for
  ///     incrementing this on every write to the same `id`.
  ///   - deviceId: Which device is performing this write.
  ///   - modifiedAt: When this revision was written. Defaults to now.
  ///   - deleted: Whether this write also tombstones the record. Defaults to `false`.
  ///   - key: The vault key to seal under.
  public static func seal(
    _ item: PasswordItem,
    version: UInt64,
    deviceId: UUID,
    modifiedAt: Date = Date(),
    deleted: Bool = false,
    key: VaultCrypto.Key
  ) throws -> VaultRecord {
    let schemaVersion = PasswordItemSchema.currentVersion
    let plaintext = try PasswordItemSchema.encodeCurrent(item)
    let aad = VaultCrypto.AAD(
      recordId: item.id,
      type: VaultRecord.RecordType.passwordItem.rawValue,
      schemaVersion: schemaVersion,
      version: version
    )
    let sealed = try VaultCrypto.seal(plaintext, aad: aad, key: key)
    return VaultRecord(
      id: item.id,
      type: .passwordItem,
      version: version,
      modifiedAt: modifiedAt,
      deviceId: deviceId,
      deleted: deleted,
      sealed: sealed,
      schemaVersion: schemaVersion
    )
  }

  /// Opens `record`, verifying it against `key` and reconstructing the exact `VaultCrypto.AAD`
  /// it was sealed with from the record's own plaintext fields, then decodes the resulting
  /// plaintext into a `PasswordItem` (migrating forward if `record.schemaVersion` is older than
  /// current).
  ///
  /// Throws whatever `VaultCrypto.open` throws (wrong key, tampered ciphertext, or — as of
  /// 851-2403 — a replayed old `version`) or `Error.unsupportedSchemaVersion` if the record's
  /// schema is newer than this build understands.
  public static func open(_ record: VaultRecord, key: VaultCrypto.Key) throws -> PasswordItem {
    let aad = VaultCrypto.AAD(
      recordId: record.id,
      type: record.type.rawValue,
      schemaVersion: record.schemaVersion,
      version: record.version
    )
    let plaintext = try VaultCrypto.open(record.sealed, aad: aad, key: key)
    do {
      return try PasswordItemSchema.decode(plaintext, schemaVersion: record.schemaVersion)
    } catch let error as PasswordItemSchema.Error {
      switch error {
      case .unsupportedSchemaVersion(let version):
        throw Error.unsupportedSchemaVersion(version)
      }
    }
  }
}
