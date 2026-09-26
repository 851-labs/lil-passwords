import Foundation

/// Versioned encoding/decoding for `PasswordItem`'s plaintext, keyed by `VaultRecord.schemaVersion`.
///
/// `RecordCodec` always *writes* `currentVersion`, but must keep being able to *read* every
/// older version indefinitely — a vault's records don't get rewritten just because the app
/// updated. Each case below is a frozen snapshot of a past on-disk shape plus a `migrated()`
/// step forward; `decode` dispatches to the right one and returns a current-shape `PasswordItem`
/// either way, so every other layer only ever has to deal with one shape.
enum PasswordItemSchema {
  /// The schema version `RecordCodec.seal` writes today. Bump this and add a case to `decode`
  /// (plus a legacy struct like `V1` below) whenever `PasswordItem`'s encoded shape changes in a
  /// way `Codable`'s own defaulting can't absorb.
  static let currentVersion: UInt32 = 2

  enum Error: Swift.Error, Equatable, Sendable {
    /// The record's `schemaVersion` is newer than this build knows how to decode — e.g. a vault
    /// synced from a newer app version. Distinct from `VaultCrypto.Error.unsupportedFormatVersion`,
    /// which is about the sealing/wrapping wire format, not the item's own encoded shape.
    case unsupportedSchemaVersion(UInt32)
  }

  /// Decodes `data` (already opened by `VaultCrypto.open`) as `PasswordItem`, migrating forward
  /// from `schemaVersion` if it isn't `currentVersion`.
  static func decode(_ data: Data, schemaVersion: UInt32) throws -> PasswordItem {
    switch schemaVersion {
    case 1:
      return try JSONDecoder().decode(V1.self, from: data).migrated()
    case Self.currentVersion:
      return try JSONDecoder().decode(PasswordItem.self, from: data)
    default:
      throw Error.unsupportedSchemaVersion(schemaVersion)
    }
  }

  /// Encodes `item` at `currentVersion` — the only version `RecordCodec.seal` ever writes.
  static func encodeCurrent(_ item: PasswordItem) throws -> Data {
    try JSONEncoder().encode(item)
  }

  /// Schema version 1: `websites` was free-form strings, taken as-is from whatever the caller
  /// supplied (e.g. an unvalidated CSV import row), with no guarantee they were even well-formed
  /// URLs. Superseded by version 2's `[URL]`, which pushes that validation to construction time
  /// instead of leaving it to whatever eventually tries to render or open the URL.
  ///
  /// Kept around solely so `decode` can still open a version-1 record; nothing in this build
  /// ever writes this shape again.
  fileprivate struct V1: Codable {
    var id: UUID
    var title: String
    var usernames: [String]
    var password: String
    var websites: [String]
    var notes: String
    var totpURI: String?
    var group: String?
    var createdAt: Date
    var modifiedAt: Date
    var lastUsedAt: Date?
    var deletedAt: Date?
    var securityWarningHidden: Bool

    /// Migrates to the current shape. Websites that don't parse as a `URL` are dropped rather
    /// than failing the whole migration — a single bad legacy string shouldn't make an entire
    /// item unreadable.
    func migrated() -> PasswordItem {
      PasswordItem(
        id: id,
        title: title,
        usernames: usernames,
        password: password,
        websites: websites.compactMap { URL(string: $0) },
        notes: notes,
        totpURI: totpURI,
        group: group,
        createdAt: createdAt,
        modifiedAt: modifiedAt,
        lastUsedAt: lastUsedAt,
        deletedAt: deletedAt,
        securityWarningHidden: securityWarningHidden
      )
    }
  }
}
