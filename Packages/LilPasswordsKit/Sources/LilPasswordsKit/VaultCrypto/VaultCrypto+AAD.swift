import Foundation

extension VaultCrypto {
  /// The associated data authenticated (but not encrypted) alongside a sealed item.
  ///
  /// Binding the ciphertext to `recordId`, `type`, and `schemaVersion` means a sealed blob can
  /// only be opened in the exact row and context it was sealed for: an attacker with write
  /// access to the vault database can't copy one row's ciphertext into another row, into a
  /// column of a different item type, or reuse it after a schema migration, without the open
  /// failing.
  ///
  /// `version` additionally binds the ciphertext to the record's own revision counter (see
  /// `VaultRecord.version`), so an old sealed copy of a row can't be replayed back over a newer
  /// one — copying an old ciphertext into a row now claiming a different `version` makes the
  /// open fail, the same way a mismatched `recordId` or `type` does. This was added after the
  /// initial crypto ADR shipped (851-2403, a crypto-review follow-up); it defaults to `0` so
  /// existing call sites that don't yet have a meaningful revision counter keep compiling, but
  /// any caller that tracks revisions — `RecordCodec`, and eventually `VaultStore` — should
  /// always pass the real value. See "AAD includes the record version" in
  /// `docs/adr/0002-crypto.md`.
  public struct AAD: Sendable, Equatable {
    public let recordId: UUID
    public let type: String
    public let schemaVersion: UInt32
    public let version: UInt64

    public init(recordId: UUID, type: String, schemaVersion: UInt32, version: UInt64 = 0) {
      self.recordId = recordId
      self.type = type
      self.schemaVersion = schemaVersion
      self.version = version
    }

    /// A deterministic, unambiguous binary encoding used as AES-GCM's authenticated data.
    /// Fields are length-prefixed (where variable-length) so there's no way for two different
    /// (recordId, type) pairs to encode to the same bytes.
    var encoded: Data {
      var data = Data()
      Self.appendLengthPrefixed(recordId.uuidString, to: &data)
      Self.appendLengthPrefixed(type, to: &data)
      var schemaVersionValue = schemaVersion.bigEndian
      withUnsafeBytes(of: &schemaVersionValue) { data.append(contentsOf: $0) }
      var versionValue = version.bigEndian
      withUnsafeBytes(of: &versionValue) { data.append(contentsOf: $0) }
      return data
    }

    private static func appendLengthPrefixed(_ string: String, to data: inout Data) {
      let utf8 = Data(string.utf8)
      var length = UInt32(utf8.count).bigEndian
      withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
      data.append(utf8)
    }
  }
}
