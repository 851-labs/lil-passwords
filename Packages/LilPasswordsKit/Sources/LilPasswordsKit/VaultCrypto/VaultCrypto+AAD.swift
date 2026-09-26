import Foundation

extension VaultCrypto {
  /// The associated data authenticated (but not encrypted) alongside a sealed item.
  ///
  /// Binding the ciphertext to `recordId`, `type`, and `schemaVersion` means a sealed blob can
  /// only be opened in the exact row and context it was sealed for: an attacker with write
  /// access to the vault database can't copy one row's ciphertext into another row, into a
  /// column of a different item type, or reuse it after a schema migration, without the open
  /// failing.
  public struct AAD: Sendable, Equatable {
    public let recordId: UUID
    public let type: String
    public let schemaVersion: UInt32

    public init(recordId: UUID, type: String, schemaVersion: UInt32) {
      self.recordId = recordId
      self.type = type
      self.schemaVersion = schemaVersion
    }

    /// A deterministic, unambiguous binary encoding used as AES-GCM's authenticated data.
    /// Fields are length-prefixed so there's no way for two different (recordId, type)
    /// pairs to encode to the same bytes.
    var encoded: Data {
      var data = Data()
      Self.appendLengthPrefixed(recordId.uuidString, to: &data)
      Self.appendLengthPrefixed(type, to: &data)
      var version = schemaVersion.bigEndian
      withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
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
