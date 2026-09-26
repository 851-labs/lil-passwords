import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct RecordCodecTests {
  private func makeItem() -> PasswordItem {
    PasswordItem(
      title: "Example",
      usernames: ["alice@example.com"],
      password: "correct-horse-battery-staple",
      websites: [URL(string: "https://example.com")!],
      notes: "Some notes",
      group: "Work"
    )
  }

  @Test func sealThenOpenRoundTripsTheItem() throws {
    let key = VaultCrypto.Key.generate()
    let deviceId = UUID()
    let item = makeItem()

    let record = try RecordCodec.seal(item, version: 1, deviceId: deviceId, key: key)
    let opened = try RecordCodec.open(record, key: key)

    #expect(opened == item)
    #expect(record.id == item.id)
    #expect(record.type == .passwordItem)
    #expect(record.version == 1)
    #expect(record.deviceId == deviceId)
    #expect(record.deleted == false)
    #expect(record.schemaVersion == PasswordItemSchema.currentVersion)
  }

  @Test func sealNeverLeaksPlaintextIntoTheEnvelope() throws {
    let key = VaultCrypto.Key.generate()
    let item = makeItem()

    let record = try RecordCodec.seal(item, version: 1, deviceId: UUID(), key: key)
    let envelope = try JSONEncoder().encode(record)
    let envelopeString = String(decoding: envelope, as: UTF8.self)

    #expect(!envelopeString.contains(item.title))
    #expect(!envelopeString.contains(item.password))
    #expect(!envelopeString.contains("example.com"))
  }

  @Test func openFailsWhenCiphertextIsTamperedWith() throws {
    let key = VaultCrypto.Key.generate()
    var record = try RecordCodec.seal(makeItem(), version: 1, deviceId: UUID(), key: key)

    var combined = record.sealed.combined
    combined[combined.count - 1] ^= 0xFF
    record.sealed = VaultCrypto.SealedItem(keyId: record.sealed.keyId, combined: combined)

    #expect(throws: VaultCrypto.Error.authenticationFailed) {
      _ = try RecordCodec.open(record, key: key)
    }
  }

  @Test func openFailsWithTheWrongKey() throws {
    let sealingKey = VaultCrypto.Key.generate()
    let otherKey = VaultCrypto.Key.generate()
    let record = try RecordCodec.seal(makeItem(), version: 1, deviceId: UUID(), key: sealingKey)

    #expect(throws: VaultCrypto.Error.keyMismatch(expected: sealingKey.id, found: otherKey.id)) {
      _ = try RecordCodec.open(record, key: otherKey)
    }
  }

  @Test func openRejectsAReplayedOldVersion() throws {
    // An attacker (or a buggy sync client) with write access to the vault database copies an
    // old revision's `sealed` blob back over a row that has since moved to a newer `version`.
    // The row's plaintext `version` column now says 2, but the ciphertext was sealed for
    // version 1 — `RecordCodec.open` must catch this rather than silently resurrecting the
    // stale revision 1 content. See "AAD includes the record version" in
    // docs/adr/0002-crypto.md.
    let key = VaultCrypto.Key.generate()
    let deviceId = UUID()
    var oldItem = makeItem()
    oldItem.password = "old-password"
    let staleRecord = try RecordCodec.seal(oldItem, version: 1, deviceId: deviceId, key: key)

    var replayed = staleRecord
    replayed.version = 2

    #expect(throws: VaultCrypto.Error.authenticationFailed) {
      _ = try RecordCodec.open(replayed, key: key)
    }

    // Opening the untouched, correctly-versioned record still works.
    #expect(try RecordCodec.open(staleRecord, key: key).password == "old-password")
  }

  @Test func openMigratesASchemaVersion1RecordForward() throws {
    // Hand-builds a schema-version-1 record the way an old build would have written it —
    // `websites` as unvalidated strings, including one that isn't a well-formed URL — to
    // exercise `PasswordItemSchema`'s migration path end to end, independent of whether this
    // build's `RecordCodec.seal` ever produces version 1 itself.
    let key = VaultCrypto.Key.generate()
    let recordId = UUID()
    let now = Date()

    struct LegacyV1: Encodable {
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
    }

    let legacy = LegacyV1(
      id: recordId,
      title: "Legacy Example",
      usernames: ["bob@example.com"],
      password: "legacy-password",
      websites: ["https://example.com", ""],
      notes: "",
      totpURI: nil,
      group: nil,
      createdAt: now,
      modifiedAt: now,
      lastUsedAt: nil,
      deletedAt: nil,
      securityWarningHidden: false
    )
    let plaintext = try JSONEncoder().encode(legacy)
    let aad = VaultCrypto.AAD(
      recordId: recordId,
      type: VaultRecord.RecordType.passwordItem.rawValue,
      schemaVersion: 1,
      version: 1
    )
    let sealed = try VaultCrypto.seal(plaintext, aad: aad, key: key)
    let record = VaultRecord(
      id: recordId,
      type: .passwordItem,
      version: 1,
      modifiedAt: now,
      deviceId: UUID(),
      deleted: false,
      sealed: sealed,
      schemaVersion: 1
    )

    let opened = try RecordCodec.open(record, key: key)

    #expect(opened.title == "Legacy Example")
    #expect(opened.password == "legacy-password")
    // The malformed entry is dropped; the well-formed one survives.
    #expect(opened.websites == [URL(string: "https://example.com")!])
  }

  @Test func openRejectsAnUnsupportedSchemaVersion() throws {
    let key = VaultCrypto.Key.generate()
    let item = makeItem()
    var record = try RecordCodec.seal(item, version: 1, deviceId: UUID(), key: key)

    // Simulate a record written by a future build with a schema version this one doesn't know.
    let futureAAD = VaultCrypto.AAD(
      recordId: record.id,
      type: record.type.rawValue,
      schemaVersion: 99,
      version: record.version
    )
    let plaintext = try PasswordItemSchema.encodeCurrent(item)
    record.sealed = try VaultCrypto.seal(plaintext, aad: futureAAD, key: key)
    record.schemaVersion = 99

    #expect(throws: RecordCodec.Error.unsupportedSchemaVersion(99)) {
      _ = try RecordCodec.open(record, key: key)
    }
  }

  @Test func sealDefaultsToNotDeletedAndThreadsDeletedThrough() throws {
    let key = VaultCrypto.Key.generate()
    let deleted = try RecordCodec.seal(makeItem(), version: 3, deviceId: UUID(), deleted: true, key: key)

    #expect(deleted.deleted == true)
  }
}
