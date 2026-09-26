import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct PasswordItemCategoryFilteringTests {
  @Test func nonDeletedExcludesOnlyDeletedItems() {
    let active = PasswordItem(title: "Active")
    var deleted = PasswordItem(title: "Deleted")
    deleted.deletedAt = Date()

    let result = [active, deleted].nonDeleted()
    #expect(result.map(\.title) == ["Active"])
  }

  @Test func withVerificationCodeRequiresATotpURIAndExcludesDeletedItems() {
    let withCode = PasswordItem(title: "GitHub", totpURI: "otpauth://totp/GitHub?secret=JBSWY3DPEHPK3PXP")
    let withoutCode = PasswordItem(title: "Amazon")
    var deletedWithCode = PasswordItem(title: "Old", totpURI: "otpauth://totp/Old?secret=JBSWY3DPEHPK3PXP")
    deletedWithCode.deletedAt = Date()

    let result = [withCode, withoutCode, deletedWithCode].withVerificationCode()
    #expect(result.map(\.title) == ["GitHub"])
  }

  @Test func recentlyDeletedReturnsOnlyDeletedItems() {
    let active = PasswordItem(title: "Active")
    var deleted = PasswordItem(title: "Deleted")
    deleted.deletedAt = Date()

    let result = [active, deleted].recentlyDeleted()
    #expect(result.map(\.title) == ["Deleted"])
  }

  @Test func sortedByDaysRemainingOrdersSoonestExpiryFirst() {
    let now = Date()
    func deletedItem(_ title: String, daysAgo: Double) -> PasswordItem {
      var item = PasswordItem(title: title)
      item.deletedAt = now.addingTimeInterval(-daysAgo * 24 * 60 * 60)
      return item
    }

    // Deleted 1 day ago -> 29 days remaining. Deleted 25 days ago -> 5 days remaining.
    let soonToExpire = deletedItem("Soon", daysAgo: 25)
    let justDeleted = deletedItem("JustDeleted", daysAgo: 1)

    let result = [justDeleted, soonToExpire].sortedByDaysRemaining(now: now)
    #expect(result.map(\.title) == ["Soon", "JustDeleted"])
  }

  @Test func sortedByDaysRemainingTieBreaksByTitle() {
    let now = Date()
    func deletedItem(_ title: String) -> PasswordItem {
      var item = PasswordItem(title: title)
      item.deletedAt = now
      return item
    }

    let result = [deletedItem("Zebra"), deletedItem("Apple")].sortedByDaysRemaining(now: now)
    #expect(result.map(\.title) == ["Apple", "Zebra"])
  }
}
