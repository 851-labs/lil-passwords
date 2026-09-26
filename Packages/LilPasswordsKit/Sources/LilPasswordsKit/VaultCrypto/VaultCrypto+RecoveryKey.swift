import Foundation

extension VaultCrypto {
  /// A high-entropy recovery secret: 160 bits of randomness the user can write down, shown as
  /// grouped, human-transcribable Crockford Base32 with a trailing checksum byte.
  ///
  /// Because this is machine-generated randomness — not a password a person chose — HKDF alone
  /// is an appropriate way to derive a wrapping key from it. There's no need for a slow,
  /// memory-hard KDF here; those exist to slow down guessing *low*-entropy secrets, and 160
  /// random bits aren't guessable.
  public struct RecoveryKey: Sendable, Equatable {
    /// 160 bits, matching the ticket's floor for recovery-key entropy.
    public static let byteCount = 20
    private static let displayGroupSize = 4

    public let entropy: Data

    public init(entropy: Data) throws {
      guard entropy.count == Self.byteCount else {
        throw VaultCrypto.Error.invalidRecoveryKeySize
      }
      self.entropy = entropy
    }

    /// Generates a fresh recovery key from 160 bits of cryptographically random data.
    public static func generate() -> RecoveryKey {
      try! RecoveryKey(entropy: SecureRandom.bytes(byteCount))
    }

    /// A grouped, uppercase Crockford Base32 rendering with a trailing checksum character,
    /// e.g. `4S9K-D2XQ-7RTN-...`. Suitable for printing on a recovery card.
    public var displayString: String {
      let checksum = CRC8.checksum(entropy)
      let encoded = Base32Crockford.encode(entropy + Data([checksum]))
      return Self.grouped(encoded)
    }

    /// Parses a string produced by `displayString`. Tolerant of dashes, whitespace, lowercase
    /// input, and the Crockford `O`/`I`/`L` lookalike substitutions. Returns `nil` if the
    /// string isn't valid Base32 of the right length, or if the checksum doesn't match — which
    /// catches the overwhelming majority of single-character transcription mistakes.
    public init?(displayString: String) {
      guard let payload = Base32Crockford.decode(displayString), payload.count == Self.byteCount + 1 else {
        return nil
      }
      let entropy = payload.prefix(Self.byteCount)
      let checksum = payload[payload.index(payload.startIndex, offsetBy: Self.byteCount)]
      guard CRC8.checksum(entropy) == checksum else { return nil }
      self.entropy = Data(entropy)
    }

    private static func grouped(_ string: String) -> String {
      var result = ""
      for (index, character) in string.enumerated() {
        if index > 0, index % displayGroupSize == 0 {
          result.append("-")
        }
        result.append(character)
      }
      return result
    }
  }

  /// A vault `Key` wrapped under a key derived from a `RecoveryKey`, as stored in the vault
  /// database header.
  public struct WrappedKey: Sendable, Equatable, Codable {
    public let formatVersion: UInt8
    public let keyId: UUID
    /// Random per-wrap salt fed into HKDF along with the recovery key's entropy.
    public let salt: Data
    /// AES-GCM combined (nonce + ciphertext + tag) encryption of the wrapped key's raw bytes.
    public let combined: Data

    public init(keyId: UUID, salt: Data, combined: Data, formatVersion: UInt8 = VaultCrypto.currentFormatVersion) {
      self.formatVersion = formatVersion
      self.keyId = keyId
      self.salt = salt
      self.combined = combined
    }
  }
}

extension VaultCrypto.RecoveryKey {
  /// A restore-vault UI wants to tell a user *why* the string they typed didn't work, not just
  /// that `init?(displayString:)` returned `nil` — this classifies that same failure into one of
  /// a small number of reasons a friendly error message can be built from. See
  /// ``validate(displayString:)``.
  public enum ValidationError: Swift.Error, Sendable, Equatable {
    /// The string is empty, or only whitespace/dashes.
    case empty
    /// The string doesn't decode to a Crockford Base32 payload of exactly `byteCount + 1` bytes
    /// — the wrong character(s), or too few/many of them.
    case wrongLength
    /// The string decodes to the right length, but its trailing checksum byte doesn't match the
    /// entropy it's paired with — almost always a single mistyped or mis-copied character.
    case checksumMismatch
  }

  /// `init?(displayString:)` with a specific reason attached to the failure, for a restore-vault
  /// UI that wants to surface *why* an input was rejected instead of a bare "that didn't work."
  public static func validate(displayString: String) -> Swift.Result<VaultCrypto.RecoveryKey, ValidationError> {
    if let key = VaultCrypto.RecoveryKey(displayString: displayString) {
      return .success(key)
    }

    let strippedOfSeparators = displayString.filter { !$0.isWhitespace && $0 != "-" }
    if strippedOfSeparators.isEmpty {
      return .failure(.empty)
    }
    guard let payload = Base32Crockford.decode(displayString), payload.count == Self.byteCount + 1 else {
      return .failure(.wrongLength)
    }
    // Decodes to the right length, so `init?(displayString:)` above must have rejected it for
    // failing the checksum check — that's the only other thing it verifies.
    return .failure(.checksumMismatch)
  }
}
