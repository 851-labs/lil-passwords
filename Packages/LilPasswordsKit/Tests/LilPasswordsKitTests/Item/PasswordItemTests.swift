import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct PasswordItemTests {
  private func makeItem(totpURI: String? = nil) -> PasswordItem {
    PasswordItem(
      title: "Example",
      usernames: ["alice@example.com"],
      password: "correct-horse-battery-staple",
      websites: [URL(string: "https://example.com")!],
      notes: "Some notes",
      totpURI: totpURI,
      group: "Work"
    )
  }

  @Test func initGeneratesAUniqueV7IdAndTimestampsByDefault() {
    let first = PasswordItem(title: "One")
    let second = PasswordItem(title: "Two")

    #expect(first.id != second.id)
    #expect(first.usernames.isEmpty)
    #expect(first.password.isEmpty)
    #expect(first.websites.isEmpty)
    #expect(first.securityWarningHidden == false)
    #expect(first.deletedAt == nil)
    #expect(first.lastUsedAt == nil)
  }

  @Test func codableRoundTripsEveryField() throws {
    let item = makeItem(totpURI: "otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP&issuer=Example")

    let data = try JSONEncoder().encode(item)
    let decoded = try JSONDecoder().decode(PasswordItem.self, from: data)

    #expect(decoded == item)
  }

  @Test func hashableAndEquatableAgreeWithFieldEquality() {
    let item = makeItem()
    var mutated = item
    mutated.title = "Different"

    #expect(item == item)
    #expect(item != mutated)
    #expect(Set([item, item, mutated]).count == 2)
  }

  @Test func totpParsesAValidStoredURI() throws {
    let item = makeItem(
      totpURI: "otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP&issuer=Example&digits=6&period=30")

    let totp = try #require(item.totp)
    #expect(totp.digits == 6)
    #expect(totp.period == 30)
    #expect(!totp.code().isEmpty)
  }

  @Test func totpIsNilWhenThereIsNoURI() {
    #expect(makeItem(totpURI: nil).totp == nil)
  }

  @Test func totpIsNilWhenTheURIIsMalformed() {
    #expect(makeItem(totpURI: "not a uri at all").totp == nil)
    // A well-formed URL, but not a valid otpauth:// TOTP URI (missing secret).
    #expect(makeItem(totpURI: "otpauth://totp/Example:alice").totp == nil)
  }
}
