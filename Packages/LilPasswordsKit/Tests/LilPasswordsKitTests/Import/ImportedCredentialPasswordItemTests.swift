import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct ImportedCredentialPasswordItemTests {
  @Test func asPasswordItemMapsBasicFields() {
    let imported = ImportedCredential(
      title: "Acme Corp",
      username: "alice@example.com",
      password: "correct horse battery staple",
      urls: ["https://acme.example.com"],
      notes: "some notes",
      otpAuth: nil
    )

    let item = imported.asPasswordItem()
    #expect(item.title == "Acme Corp")
    #expect(item.usernames == ["alice@example.com"])
    #expect(item.password == "correct horse battery staple")
    #expect(item.websites == [URL(string: "https://acme.example.com")!])
    #expect(item.notes == "some notes")
    #expect(item.totpURI == nil)
    #expect(item.deletedAt == nil)
  }

  @Test func asPasswordItemLeavesUsernamesEmptyWhenSourceHasNone() {
    let imported = ImportedCredential(title: "No Username", username: "", password: "p")
    let item = imported.asPasswordItem()
    #expect(item.usernames == [])
  }

  @Test func asPasswordItemNormalizesBareDomainURLs() {
    let imported = ImportedCredential(
      title: "Bare Domain",
      username: "u",
      password: "p",
      urls: ["example.com"]
    )
    let item = imported.asPasswordItem()
    #expect(item.websites == [URL(string: "https://example.com")!])
  }

  @Test func asPasswordItemDropsURLsThatDoNotParseIntoAHost() {
    let imported = ImportedCredential(
      title: "Bad URL",
      username: "u",
      password: "p",
      urls: ["not a url", "", "https://good.example.com"]
    )
    let item = imported.asPasswordItem()
    #expect(item.websites == [URL(string: "https://good.example.com")!])
  }

  @Test func asPasswordItemPassesThroughAnOTPAuthURI() {
    let uri = "otpauth://totp/Acme:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Acme"
    let imported = ImportedCredential(title: "Acme", username: "alice", password: "p", otpAuth: uri)
    let item = imported.asPasswordItem()
    #expect(item.totpURI == uri)
  }

  @Test func asPasswordItemWrapsARawBase32SecretIntoAnOTPAuthURI() throws {
    let imported = ImportedCredential(
      title: "Legacy Export",
      username: "carol@example.com",
      password: "p",
      otpAuth: "JBSWY3DPEHPK3PXP"
    )
    let item = imported.asPasswordItem()
    let totpURI = try #require(item.totpURI)
    let url = try #require(URL(string: totpURI))
    let parsed = try OTPAuthURI(url: url)
    #expect(parsed.accountName == "carol@example.com")
    #expect(Base32.encode(parsed.totp.secret) == "JBSWY3DPEHPK3PXP")
  }

  @Test func asPasswordItemToleratesBase32SecretsWithSpacesAndDashes() throws {
    let imported = ImportedCredential(
      title: "Spaced Secret",
      username: "dave",
      password: "p",
      otpAuth: "JBSW Y3DP-EHPK 3PXP"
    )
    let item = imported.asPasswordItem()
    let totpURI = try #require(item.totpURI)
    let parsed = try OTPAuthURI(url: try #require(URL(string: totpURI)))
    #expect(Base32.encode(parsed.totp.secret) == "JBSWY3DPEHPK3PXP")
  }

  @Test func asPasswordItemIgnoresUnparseableOTPAuth() {
    let imported = ImportedCredential(title: "Bad OTP", username: "u", password: "p", otpAuth: "not-base32!!")
    let item = imported.asPasswordItem()
    #expect(item.totpURI == nil)
  }

  @Test func asPasswordItemIgnoresBlankOTPAuth() {
    let imported = ImportedCredential(title: "Blank OTP", username: "u", password: "p", otpAuth: "   ")
    let item = imported.asPasswordItem()
    #expect(item.totpURI == nil)
  }

  @Test func replacingKeepsIdentityAndUpdatesContent() {
    let original = PasswordItem(
      title: "Old Title",
      usernames: ["old"],
      password: "oldpw",
      websites: [URL(string: "https://old.example.com")!],
      notes: "old notes",
      createdAt: Date(timeIntervalSince1970: 0)
    )

    let imported = ImportedCredential(
      title: "New Title",
      username: "new",
      password: "newpw",
      urls: ["https://new.example.com"],
      notes: "new notes",
      otpAuth: "otpauth://totp/New:new?secret=JBSWY3DPEHPK3PXP"
    )

    let updated = imported.replacing(original)
    #expect(updated.id == original.id)
    #expect(updated.createdAt == original.createdAt)
    #expect(updated.title == "New Title")
    #expect(updated.usernames == ["new"])
    #expect(updated.password == "newpw")
    #expect(updated.websites == [URL(string: "https://new.example.com")!])
    #expect(updated.notes == "new notes")
    #expect(updated.totpURI == "otpauth://totp/New:new?secret=JBSWY3DPEHPK3PXP")
    #expect(updated.modifiedAt > original.createdAt)
  }

  @Test func asExistingCredentialProjectsFieldsBack() {
    let item = PasswordItem(
      title: "Acme Corp",
      usernames: ["alice@example.com"],
      password: "correct horse battery staple",
      websites: [URL(string: "https://acme.example.com")!],
      notes: "some notes",
      totpURI: "otpauth://totp/Acme:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Acme"
    )

    let existing = item.asExistingCredential()
    #expect(existing.id == item.id.uuidString)
    #expect(existing.title == "Acme Corp")
    #expect(existing.username == "alice@example.com")
    #expect(existing.password == "correct horse battery staple")
    #expect(existing.urls == ["https://acme.example.com"])
    #expect(existing.notes == "some notes")
    #expect(existing.otpAuth == "otpauth://totp/Acme:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Acme")
  }

  @Test func asExistingCredentialUsesNilForEmptyNotes() {
    let item = PasswordItem(title: "No Notes", usernames: [], password: "p")
    #expect(item.asExistingCredential().notes == nil)
  }

  @Test func roundTripThroughMergePlannerRecognizesAnUnchangedItemAsADuplicate() {
    let imported = ImportedCredential(
      title: "Acme Corp",
      username: "alice@example.com",
      password: "correct horse battery staple",
      urls: ["https://acme.example.com"],
      notes: "some notes"
    )
    let existingItem = imported.asPasswordItem()

    let plan = ImportMergePlanner.plan(importing: [imported], against: [existingItem.asExistingCredential()])
    #expect(plan.duplicates.count == 1)
    #expect(plan.newCredentials.isEmpty)
    #expect(plan.conflicts.isEmpty)
  }

  @Test func roundTripThroughMergePlannerRecognizesAChangedPasswordAsAConflict() {
    let imported = ImportedCredential(
      title: "Acme Corp",
      username: "alice@example.com",
      password: "new-password",
      urls: ["https://acme.example.com"],
      notes: "some notes"
    )
    var existingItem = imported.asPasswordItem()
    existingItem.password = "old-password"

    let plan = ImportMergePlanner.plan(importing: [imported], against: [existingItem.asExistingCredential()])
    #expect(plan.conflicts.count == 1)
  }
}
