import Foundation

/// Versioned encoding/decoding for `PasskeyItem`'s plaintext, keyed by `VaultRecord.schemaVersion`.
///
/// Mirrors `PasswordItemSchema`'s shape exactly, one version behind: `PasskeyItem` is new as of
/// this ticket, so there is no legacy version to migrate from yet. Kept as its own `switch`
/// (rather than, say, `default: throw` for everything but current) so the very first future
/// migration only has to add a case here, the same way `PasswordItemSchema` did.
enum PasskeyItemSchema {
  /// The schema version `PasskeyRecordCodec.seal` writes today.
  static let currentVersion: UInt32 = 1

  enum Error: Swift.Error, Equatable, Sendable {
    /// The record's `schemaVersion` is newer than this build knows how to decode.
    case unsupportedSchemaVersion(UInt32)
  }

  /// Decodes `data` (already opened by `VaultCrypto.open`) as `PasskeyItem`.
  static func decode(_ data: Data, schemaVersion: UInt32) throws -> PasskeyItem {
    switch schemaVersion {
    case Self.currentVersion:
      return try JSONDecoder().decode(PasskeyItem.self, from: data)
    default:
      throw Error.unsupportedSchemaVersion(schemaVersion)
    }
  }

  /// Encodes `item` at `currentVersion` — the only version `PasskeyRecordCodec.seal` ever writes.
  static func encodeCurrent(_ item: PasskeyItem) throws -> Data {
    try JSONEncoder().encode(item)
  }
}
