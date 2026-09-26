import CryptoKit
import Foundation

extension VaultCrypto {
  /// A vault key: 256 bits of random key material identified by `id`.
  ///
  /// `Key` carries no notion of a master password — MVP vaults have none. It is generated
  /// once per vault, held in memory by `LilPasswordsAgent` while unlocked, and persisted
  /// either in the local (non-synced) Keychain or, wrapped under a recovery key, in the vault
  /// database header.
  public struct Key: Sendable, Equatable {
    /// Identifies this key, so a `SealedItem` can record which key it was encrypted under,
    /// and vaults can support key rotation later without breaking existing ciphertext.
    public let id: UUID

    /// The raw 256-bit key material. Treat this as highly sensitive: anyone who has it can
    /// decrypt the entire vault.
    public let rawData: Data

    public init(id: UUID = UUID(), rawData: Data) throws {
      guard rawData.count == VaultCrypto.keyByteCount else {
        throw VaultCrypto.Error.invalidKeySize
      }
      self.id = id
      self.rawData = rawData
    }

    /// Generates a fresh, cryptographically random 256-bit vault key.
    public static func generate() -> Key {
      try! Key(id: UUID(), rawData: SecureRandom.bytes(VaultCrypto.keyByteCount))
    }

    var symmetricKey: SymmetricKey { SymmetricKey(data: rawData) }
  }
}
