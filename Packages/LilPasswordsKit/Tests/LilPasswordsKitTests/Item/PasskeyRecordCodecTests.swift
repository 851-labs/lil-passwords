import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct PasskeyRecordCodecTests {
  private func makeItem() -> PasskeyItem {
    PasskeyItem(
      relyingPartyIdentifier: "webauthn.io",
      userHandle: Data([0x01, 0x02, 0x03, 0x04]),
      userName: "alice@example.com",
      userDisplayName: "Alice Example",
      credentialId: Data(repeating: 0xAB, count: 16),
      privateKeyPKCS8: Data(repeating: 0xCD, count: 138)
    )
  }

  @Test func sealThenOpenRoundTripsTheItem() throws {
    let key = VaultCrypto.Key.generate()
    let deviceId = UUID()
    let item = makeItem()

    let record = try PasskeyRecordCodec.seal(item, version: 1, deviceId: deviceId, key: key)
    let opened = try PasskeyRecordCodec.open(record, key: key)

    #expect(opened == item)
    #expect(record.id == item.id)
    #expect(record.type == .passkeyItem)
    #expect(record.version == 1)
    #expect(record.deviceId == deviceId)
    #expect(record.deleted == false)
    #expect(record.schemaVersion == PasskeyItemSchema.currentVersion)
  }

  @Test func sealNeverLeaksPlaintextIntoTheEnvelope() throws {
    let key = VaultCrypto.Key.generate()
    let item = makeItem()

    let record = try PasskeyRecordCodec.seal(item, version: 1, deviceId: UUID(), key: key)
    let envelope = try JSONEncoder().encode(record)
    let envelopeString = String(decoding: envelope, as: UTF8.self)

    #expect(!envelopeString.contains(item.relyingPartyIdentifier))
    #expect(!envelopeString.contains(item.userName))
    // The one field this ticket's whole trust model exists to protect: the private key must
    // never show up outside the sealed ciphertext, not even as a base64 substring.
    #expect(!envelopeString.contains(item.privateKeyPKCS8.base64EncodedString()))
  }

  @Test func openFailsWhenCiphertextIsTamperedWith() throws {
    let key = VaultCrypto.Key.generate()
    var record = try PasskeyRecordCodec.seal(makeItem(), version: 1, deviceId: UUID(), key: key)

    var combined = record.sealed.combined
    combined[combined.count - 1] ^= 0xFF
    record.sealed = VaultCrypto.SealedItem(keyId: record.sealed.keyId, combined: combined)

    #expect(throws: VaultCrypto.Error.authenticationFailed) {
      _ = try PasskeyRecordCodec.open(record, key: key)
    }
  }

  @Test func openFailsWithTheWrongKey() throws {
    let sealingKey = VaultCrypto.Key.generate()
    let otherKey = VaultCrypto.Key.generate()
    let record = try PasskeyRecordCodec.seal(makeItem(), version: 1, deviceId: UUID(), key: sealingKey)

    #expect(throws: VaultCrypto.Error.keyMismatch(expected: sealingKey.id, found: otherKey.id)) {
      _ = try PasskeyRecordCodec.open(record, key: otherKey)
    }
  }

  @Test func openRejectsAReplayedOldVersion() throws {
    // Mirrors RecordCodecTests.openRejectsAReplayedOldVersion — see that test and "AAD includes
    // the record version" in docs/adr/0002-crypto.md.
    let key = VaultCrypto.Key.generate()
    let deviceId = UUID()
    var oldItem = makeItem()
    oldItem.signCount = 1
    let staleRecord = try PasskeyRecordCodec.seal(oldItem, version: 1, deviceId: deviceId, key: key)

    var replayed = staleRecord
    replayed.version = 2

    #expect(throws: VaultCrypto.Error.authenticationFailed) {
      _ = try PasskeyRecordCodec.open(replayed, key: key)
    }

    #expect(try PasskeyRecordCodec.open(staleRecord, key: key).signCount == 1)
  }

  @Test func openMigratesASchemaVersion1RecordForward() throws {
    // `PasskeyItemSchema.currentVersion` is 1 today — there is no prior legacy shape to migrate
    // from yet, so this exercises the same "decode exactly what a version-1 build wrote" path
    // `RecordCodecTests.openMigratesASchemaVersion1RecordForward` exercises for a true migration,
    // hand-building the record the way `PasskeyItemSchema.decode`'s `case Self.currentVersion`
    // branch expects rather than going through `PasskeyRecordCodec.seal`. When a schema version 2
    // is introduced, this test's hand-built shape should stay pinned to version 1's fields so it
    // keeps proving the codec can still open what's on disk today.
    let key = VaultCrypto.Key.generate()
    let recordId = UUID()
    let now = Date()
    let item = PasskeyItem(
      id: recordId,
      relyingPartyIdentifier: "example.com",
      userHandle: Data([0x0A]),
      userName: "bob@example.com",
      userDisplayName: "Bob Example",
      credentialId: Data(repeating: 0xEF, count: 16),
      privateKeyPKCS8: Data(repeating: 0x11, count: 138),
      signCount: 3,
      createdAt: now,
      lastUsedAt: now
    )
    let plaintext = try JSONEncoder().encode(item)
    let aad = VaultCrypto.AAD(
      recordId: recordId,
      type: VaultRecord.RecordType.passkeyItem.rawValue,
      schemaVersion: 1,
      version: 1
    )
    let sealed = try VaultCrypto.seal(plaintext, aad: aad, key: key)
    let record = VaultRecord(
      id: recordId,
      type: .passkeyItem,
      version: 1,
      modifiedAt: now,
      deviceId: UUID(),
      deleted: false,
      sealed: sealed,
      schemaVersion: 1
    )

    let opened = try PasskeyRecordCodec.open(record, key: key)

    #expect(opened == item)
  }

  @Test func openRejectsAnUnsupportedSchemaVersion() throws {
    let key = VaultCrypto.Key.generate()
    let item = makeItem()
    var record = try PasskeyRecordCodec.seal(item, version: 1, deviceId: UUID(), key: key)

    let futureAAD = VaultCrypto.AAD(
      recordId: record.id,
      type: record.type.rawValue,
      schemaVersion: 99,
      version: record.version
    )
    let plaintext = try PasskeyItemSchema.encodeCurrent(item)
    record.sealed = try VaultCrypto.seal(plaintext, aad: futureAAD, key: key)
    record.schemaVersion = 99

    #expect(throws: PasskeyRecordCodec.Error.unsupportedSchemaVersion(99)) {
      _ = try PasskeyRecordCodec.open(record, key: key)
    }
  }

  @Test func sealDefaultsToNotDeletedAndThreadsDeletedThrough() throws {
    let key = VaultCrypto.Key.generate()
    let deleted = try PasskeyRecordCodec.seal(makeItem(), version: 3, deviceId: UUID(), deleted: true, key: key)

    #expect(deleted.deleted == true)
  }
}
