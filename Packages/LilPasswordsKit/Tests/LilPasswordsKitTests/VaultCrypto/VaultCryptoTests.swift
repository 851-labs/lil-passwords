import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct VaultCryptoKeyTests {
  @Test func generateProducesA256BitKeyWithAUniqueId() {
    let first = VaultCrypto.Key.generate()
    let second = VaultCrypto.Key.generate()

    #expect(first.rawData.count == 32)
    #expect(first.id != second.id)
    #expect(first.rawData != second.rawData)
  }

  @Test func initRejectsTheWrongKeySize() {
    #expect(throws: VaultCrypto.Error.invalidKeySize) {
      _ = try VaultCrypto.Key(rawData: Data(repeating: 0, count: 16))
    }
  }
}

@Suite struct VaultCryptoSealingTests {
  private func makeAAD(
    recordId: UUID = UUID(),
    type: String = "login",
    schemaVersion: UInt32 = 1,
    version: UInt64 = 0
  ) -> VaultCrypto.AAD {
    VaultCrypto.AAD(recordId: recordId, type: type, schemaVersion: schemaVersion, version: version)
  }

  @Test func sealThenOpenRoundTripsThePlaintext() throws {
    let key = VaultCrypto.Key.generate()
    let aad = makeAAD()
    let plaintext = Data("correct horse battery staple".utf8)

    let sealed = try VaultCrypto.seal(plaintext, aad: aad, key: key)
    let opened = try VaultCrypto.open(sealed, aad: aad, key: key)

    #expect(opened == plaintext)
    #expect(sealed.keyId == key.id)
  }

  @Test func sealProducesDifferentCiphertextEachTime() throws {
    let key = VaultCrypto.Key.generate()
    let aad = makeAAD()
    let plaintext = Data("hunter2".utf8)

    let first = try VaultCrypto.seal(plaintext, aad: aad, key: key)
    let second = try VaultCrypto.seal(plaintext, aad: aad, key: key)

    // A fresh random nonce each time means identical plaintext never produces identical
    // ciphertext, so the vault database can't leak "these two items are equal" via ciphertext
    // comparison.
    #expect(first.combined != second.combined)
  }

  @Test func openFailsWithAMismatchedRecordId() throws {
    let key = VaultCrypto.Key.generate()
    let sealed = try VaultCrypto.seal(Data("secret".utf8), aad: makeAAD(recordId: UUID()), key: key)

    #expect(throws: VaultCrypto.Error.authenticationFailed) {
      _ = try VaultCrypto.open(sealed, aad: self.makeAAD(recordId: UUID()), key: key)
    }
  }

  @Test func openFailsWithAMismatchedType() throws {
    let key = VaultCrypto.Key.generate()
    let recordId = UUID()
    let sealed = try VaultCrypto.seal(Data("secret".utf8), aad: makeAAD(recordId: recordId, type: "login"), key: key)

    #expect(throws: VaultCrypto.Error.authenticationFailed) {
      _ = try VaultCrypto.open(sealed, aad: self.makeAAD(recordId: recordId, type: "note"), key: key)
    }
  }

  @Test func openFailsWithAMismatchedSchemaVersion() throws {
    let key = VaultCrypto.Key.generate()
    let recordId = UUID()
    let sealed = try VaultCrypto.seal(
      Data("secret".utf8),
      aad: makeAAD(recordId: recordId, schemaVersion: 1),
      key: key
    )

    #expect(throws: VaultCrypto.Error.authenticationFailed) {
      _ = try VaultCrypto.open(sealed, aad: self.makeAAD(recordId: recordId, schemaVersion: 2), key: key)
    }
  }

  @Test func openFailsWithAMismatchedVersion() throws {
    let key = VaultCrypto.Key.generate()
    let recordId = UUID()
    // Simulates an attacker (or a buggy sync client) copying an old revision's ciphertext back
    // over a row that has since moved to a newer version — the exact replay `AAD.version` exists
    // to catch. See "AAD includes the record version" in docs/adr/0002-crypto.md.
    let staleSealed = try VaultCrypto.seal(
      Data("old value".utf8),
      aad: makeAAD(recordId: recordId, version: 1),
      key: key
    )

    #expect(throws: VaultCrypto.Error.authenticationFailed) {
      _ = try VaultCrypto.open(staleSealed, aad: self.makeAAD(recordId: recordId, version: 2), key: key)
    }
  }

  @Test func openFailsWithTheWrongKey() throws {
    let sealingKey = VaultCrypto.Key.generate()
    let otherKey = VaultCrypto.Key.generate()
    let aad = makeAAD()
    let sealed = try VaultCrypto.seal(Data("secret".utf8), aad: aad, key: sealingKey)

    #expect(throws: VaultCrypto.Error.keyMismatch(expected: sealingKey.id, found: otherKey.id)) {
      _ = try VaultCrypto.open(sealed, aad: aad, key: otherKey)
    }
  }

  @Test func openFailsWhenCiphertextIsTamperedWith() throws {
    let key = VaultCrypto.Key.generate()
    let aad = makeAAD()
    let sealed = try VaultCrypto.seal(Data("secret".utf8), aad: aad, key: key)

    var tamperedCombined = sealed.combined
    tamperedCombined[tamperedCombined.count - 1] ^= 0xFF
    let tampered = VaultCrypto.SealedItem(keyId: sealed.keyId, combined: tamperedCombined)

    #expect(throws: VaultCrypto.Error.authenticationFailed) {
      _ = try VaultCrypto.open(tampered, aad: aad, key: key)
    }
  }

  @Test func openRejectsAnUnsupportedFormatVersion() throws {
    let key = VaultCrypto.Key.generate()
    let aad = makeAAD()
    let sealed = try VaultCrypto.seal(Data("secret".utf8), aad: aad, key: key)
    let future = VaultCrypto.SealedItem(keyId: sealed.keyId, combined: sealed.combined, formatVersion: 2)

    #expect(throws: VaultCrypto.Error.unsupportedFormatVersion(2)) {
      _ = try VaultCrypto.open(future, aad: aad, key: key)
    }
  }

  @Test func sealedItemRoundTripsThroughCodable() throws {
    let key = VaultCrypto.Key.generate()
    let sealed = try VaultCrypto.seal(Data("secret".utf8), aad: makeAAD(), key: key)

    let data = try JSONEncoder().encode(sealed)
    let decoded = try JSONDecoder().decode(VaultCrypto.SealedItem.self, from: data)

    #expect(decoded == sealed)
  }
}

@Suite struct VaultCryptoRecoveryKeyTests {
  @Test func generateProducesA160BitKey() {
    let key = VaultCrypto.RecoveryKey.generate()
    #expect(key.entropy.count == 20)
  }

  @Test func initRejectsTheWrongEntropySize() {
    #expect(throws: VaultCrypto.Error.invalidRecoveryKeySize) {
      _ = try VaultCrypto.RecoveryKey(entropy: Data(repeating: 0, count: 10))
    }
  }

  @Test func displayStringRoundTrips() throws {
    let key = VaultCrypto.RecoveryKey.generate()
    let displayString = key.displayString

    let parsed = try #require(VaultCrypto.RecoveryKey(displayString: displayString))
    #expect(parsed == key)
  }

  @Test func displayStringIsGroupedWithDashes() {
    let key = try! VaultCrypto.RecoveryKey(entropy: Data(repeating: 0xAB, count: 20))
    let groups = key.displayString.split(separator: "-")

    #expect(groups.count > 1)
    for group in groups.dropLast() {
      #expect(group.count == 4)
    }
  }

  @Test func parsingToleratesCaseWhitespaceAndDashes() throws {
    let key = VaultCrypto.RecoveryKey.generate()
    let messy = key.displayString.lowercased().replacingOccurrences(of: "-", with: " ")

    let parsed = try #require(VaultCrypto.RecoveryKey(displayString: messy))
    #expect(parsed == key)
  }

  @Test func parsingRejectsASingleCharacterTypo() {
    let key = VaultCrypto.RecoveryKey.generate()
    var displayString = key.displayString

    // Flip the first character to something else in the alphabet, simulating a transcription
    // mistake. The checksum should catch this.
    let firstIndex = displayString.index(displayString.startIndex, offsetBy: 0)
    let original = displayString[firstIndex]
    let replacement: Character = original == "0" ? "1" : "0"
    displayString.replaceSubrange(firstIndex...firstIndex, with: String(replacement))

    #expect(VaultCrypto.RecoveryKey(displayString: displayString) == nil)
  }

  @Test func parsingRejectsGarbageInput() {
    #expect(VaultCrypto.RecoveryKey(displayString: "not a recovery key") == nil)
    #expect(VaultCrypto.RecoveryKey(displayString: "") == nil)
  }
}

@Suite struct VaultCryptoRecoveryWrapTests {
  @Test func wrapThenUnwrapRecoversTheOriginalKey() throws {
    let vaultKey = VaultCrypto.Key.generate()
    let recoveryKey = VaultCrypto.RecoveryKey.generate()

    let wrapped = try VaultCrypto.wrapKey(vaultKey, recoveryKey: recoveryKey)
    let unwrapped = try VaultCrypto.unwrapKey(wrapped, recoveryKey: recoveryKey)

    #expect(unwrapped == vaultKey)
    #expect(wrapped.keyId == vaultKey.id)
  }

  @Test func unwrapFailsWithTheWrongRecoveryKey() throws {
    let vaultKey = VaultCrypto.Key.generate()
    let wrapped = try VaultCrypto.wrapKey(vaultKey, recoveryKey: .generate())

    #expect(throws: VaultCrypto.Error.authenticationFailed) {
      _ = try VaultCrypto.unwrapKey(wrapped, recoveryKey: .generate())
    }
  }

  @Test func wrappingTheSameKeyTwiceProducesDifferentSaltsAndCiphertext() throws {
    let vaultKey = VaultCrypto.Key.generate()
    let recoveryKey = VaultCrypto.RecoveryKey.generate()

    let first = try VaultCrypto.wrapKey(vaultKey, recoveryKey: recoveryKey)
    let second = try VaultCrypto.wrapKey(vaultKey, recoveryKey: recoveryKey)

    #expect(first.salt != second.salt)
    #expect(first.combined != second.combined)
  }

  @Test func unwrapRejectsAnUnsupportedFormatVersion() throws {
    let vaultKey = VaultCrypto.Key.generate()
    let recoveryKey = VaultCrypto.RecoveryKey.generate()
    let wrapped = try VaultCrypto.wrapKey(vaultKey, recoveryKey: recoveryKey)
    let future = VaultCrypto.WrappedKey(
      keyId: wrapped.keyId,
      salt: wrapped.salt,
      combined: wrapped.combined,
      formatVersion: 2
    )

    #expect(throws: VaultCrypto.Error.unsupportedFormatVersion(2)) {
      _ = try VaultCrypto.unwrapKey(future, recoveryKey: recoveryKey)
    }
  }

  @Test func wrappedKeyRoundTripsThroughCodable() throws {
    let vaultKey = VaultCrypto.Key.generate()
    let wrapped = try VaultCrypto.wrapKey(vaultKey, recoveryKey: .generate())

    let data = try JSONEncoder().encode(wrapped)
    let decoded = try JSONDecoder().decode(VaultCrypto.WrappedKey.self, from: data)

    #expect(decoded == wrapped)
  }
}
