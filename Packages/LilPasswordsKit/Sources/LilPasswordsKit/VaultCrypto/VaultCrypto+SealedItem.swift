import Foundation

extension VaultCrypto {
  /// The result of sealing one item's plaintext under a vault key.
  ///
  /// `combined` is AES-GCM's nonce + ciphertext + tag, as produced by
  /// `CryptoKit.AES.GCM.SealedBox.combined`. `keyId` and `formatVersion` travel alongside the
  /// ciphertext, rather than being folded into it, so a future `VaultStore` can pick the right
  /// key to decrypt with, and so the sealing scheme itself can change later without touching
  /// unrelated rows.
  public struct SealedItem: Sendable, Equatable, Codable {
    public let formatVersion: UInt8
    public let keyId: UUID
    public let combined: Data

    public init(keyId: UUID, combined: Data, formatVersion: UInt8 = VaultCrypto.currentFormatVersion) {
      self.formatVersion = formatVersion
      self.keyId = keyId
      self.combined = combined
    }
  }
}
