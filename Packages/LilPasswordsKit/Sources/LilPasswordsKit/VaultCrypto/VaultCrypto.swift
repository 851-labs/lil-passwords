import CryptoKit
import Foundation

/// MVP crypto primitives for the local vault: sealing and opening items under a vault key, and
/// wrapping and unwrapping that vault key under a recovery key.
///
/// See `docs/adr/0002-crypto.md` for the design rationale, full key hierarchy, and threat
/// model. In short: there is no master password. The vault key is 256 bits of randomness,
/// generated once, never derived from anything a person has to remember. It is held in memory
/// by `LilPasswordsAgent` while the vault is unlocked, and persisted either in the local
/// (non-synced) Keychain or, wrapped under a recovery key, in the vault database header.
public enum VaultCrypto {
  static let keyByteCount = 32  // 256-bit AES key.
  /// The current on-disk/wire format for `SealedItem` and `WrappedKey`. Bumping this lets a
  /// future build change the sealing or wrapping scheme while still refusing to silently
  /// misinterpret data written by an older or newer version.
  public static let currentFormatVersion: UInt8 = 1

  public enum Error: Swift.Error, Equatable, Sendable {
    /// A `Key` or unwrapped key material was not exactly 256 bits.
    case invalidKeySize
    /// A `RecoveryKey`'s entropy was not exactly `RecoveryKey.byteCount` bytes.
    case invalidRecoveryKeySize
    /// A `SealedItem` or `WrappedKey` used a format version this build doesn't understand.
    case unsupportedFormatVersion(UInt8)
    /// `open`/`unwrapKey` was called with a key whose `id` doesn't match the sealed value's.
    case keyMismatch(expected: UUID, found: UUID)
    /// AES-GCM authentication failed: wrong key, wrong AAD, or the ciphertext was tampered with.
    case authenticationFailed
  }

  // MARK: - Sealing items

  /// Seals `plaintext` with AES-256-GCM under `key`, authenticating `aad` alongside it.
  ///
  /// The exact same `aad` (record id, type, and schema version) must be supplied to `open`,
  /// or the open fails. This binds the ciphertext to the row and version it was written for,
  /// so it can't be replayed into a different row, a different item type, or an old schema.
  public static func seal(_ plaintext: some DataProtocol, aad: AAD, key: Key) throws -> SealedItem {
    let sealedBox = try AES.GCM.seal(plaintext, using: key.symmetricKey, authenticating: aad.encoded)
    guard let combined = sealedBox.combined else {
      // AES.GCM.seal(_:using:authenticating:) always generates a 12-byte nonce, so `combined`
      // is always available; this branch exists only for exhaustiveness over the optional.
      throw Error.authenticationFailed
    }
    return SealedItem(keyId: key.id, combined: combined)
  }

  /// Opens a `SealedItem` previously produced by `seal`, verifying it against `key` and `aad`.
  public static func open(_ sealedItem: SealedItem, aad: AAD, key: Key) throws -> Data {
    guard sealedItem.formatVersion == currentFormatVersion else {
      throw Error.unsupportedFormatVersion(sealedItem.formatVersion)
    }
    guard sealedItem.keyId == key.id else {
      throw Error.keyMismatch(expected: sealedItem.keyId, found: key.id)
    }
    let box: AES.GCM.SealedBox
    do {
      box = try AES.GCM.SealedBox(combined: sealedItem.combined)
    } catch {
      throw Error.authenticationFailed
    }
    do {
      return try AES.GCM.open(box, using: key.symmetricKey, authenticating: aad.encoded)
    } catch {
      throw Error.authenticationFailed
    }
  }

  // MARK: - Wrapping the vault key under a recovery key

  private static let recoveryWrapInfo = Data("com.851labs.lilpasswords.recovery-wrap.v1".utf8)
  private static let recoverySaltByteCount = 16

  /// Wraps `key` under a key derived (via HKDF) from `recoveryKey`, for storage in the vault
  /// database header. Anyone with the recovery key's display string and the vault file can
  /// recover `key` by calling `unwrapKey`, which is the whole point: the recovery key plus the
  /// database file is enough to restore the vault with no other device involved.
  public static func wrapKey(_ key: Key, recoveryKey: RecoveryKey) throws -> WrappedKey {
    let salt = SecureRandom.bytes(recoverySaltByteCount)
    let wrappingKey = deriveWrappingKey(recoveryKey: recoveryKey, salt: salt)
    let aad = Data(key.id.uuidString.utf8)
    let sealedBox = try AES.GCM.seal(key.rawData, using: wrappingKey, authenticating: aad)
    guard let combined = sealedBox.combined else {
      throw Error.authenticationFailed
    }
    return WrappedKey(keyId: key.id, salt: salt, combined: combined)
  }

  /// Reverses `wrapKey`, recovering the original vault key from `wrapped` and `recoveryKey`.
  public static func unwrapKey(_ wrapped: WrappedKey, recoveryKey: RecoveryKey) throws -> Key {
    guard wrapped.formatVersion == currentFormatVersion else {
      throw Error.unsupportedFormatVersion(wrapped.formatVersion)
    }
    let wrappingKey = deriveWrappingKey(recoveryKey: recoveryKey, salt: wrapped.salt)
    let aad = Data(wrapped.keyId.uuidString.utf8)
    let box: AES.GCM.SealedBox
    do {
      box = try AES.GCM.SealedBox(combined: wrapped.combined)
    } catch {
      throw Error.authenticationFailed
    }
    let rawKey: Data
    do {
      rawKey = try AES.GCM.open(box, using: wrappingKey, authenticating: aad)
    } catch {
      throw Error.authenticationFailed
    }
    return try Key(id: wrapped.keyId, rawData: rawKey)
  }

  private static func deriveWrappingKey(recoveryKey: RecoveryKey, salt: Data) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: recoveryKey.entropy),
      salt: salt,
      info: recoveryWrapInfo,
      outputByteCount: keyByteCount
    )
  }
}
