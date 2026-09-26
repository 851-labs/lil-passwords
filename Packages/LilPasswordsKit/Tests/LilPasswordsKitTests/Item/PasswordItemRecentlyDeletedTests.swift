import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct PasswordItemRecentlyDeletedTests {
  @Test func daysRemainingIsNilWhenTheItemIsNotDeleted() {
    let item = PasswordItem(title: "Example")
    #expect(item.daysRemaining() == nil)
  }

  @Test func daysRemainingIsThirtyRightAfterDeletion() {
    let now = Date()
    var item = PasswordItem(title: "Example")
    item.deletedAt = now

    #expect(item.daysRemaining(now: now) == 30)
    // A few seconds later still rounds up to the full 30 days, not down to 29.
    #expect(item.daysRemaining(now: now.addingTimeInterval(5)) == 30)
  }

  @Test func daysRemainingCountsDownAsTimePasses() {
    let now = Date()
    var item = PasswordItem(title: "Example")
    item.deletedAt = now

    let tenDaysLater = now.addingTimeInterval(10 * 24 * 60 * 60)
    #expect(item.daysRemaining(now: tenDaysLater) == 20)
  }

  @Test func daysRemainingClampsToZeroAndNeverGoesNegative() {
    let now = Date()
    var item = PasswordItem(title: "Example")
    item.deletedAt = now

    let atRetentionBoundary = now.addingTimeInterval(PasswordItem.recentlyDeletedRetentionPeriod)
    #expect(item.daysRemaining(now: atRetentionBoundary) == 0)

    let wellPastRetention = now.addingTimeInterval(PasswordItem.recentlyDeletedRetentionPeriod * 2)
    #expect(item.daysRemaining(now: wellPastRetention) == 0)
  }
}
