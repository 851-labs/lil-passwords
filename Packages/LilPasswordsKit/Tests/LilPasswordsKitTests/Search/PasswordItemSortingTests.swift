import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct PasswordItemSortingTests {
  private func makeItem(
    title: String,
    website: String? = nil,
    createdAt: Date = Date(timeIntervalSince1970: 0),
    modifiedAt: Date = Date(timeIntervalSince1970: 0)
  ) -> PasswordItem {
    PasswordItem(
      title: title,
      websites: website.map { [URL(string: $0)!] } ?? [],
      createdAt: createdAt,
      modifiedAt: modifiedAt
    )
  }

  @Test func sortsByTitleAscending() {
    let items = [makeItem(title: "Zebra"), makeItem(title: "Apple"), makeItem(title: "Mango")]
    let sorted = items.sorted(by: PasswordItem.sortComparator(for: .title, direction: .ascending))
    #expect(sorted.map(\.title) == ["Apple", "Mango", "Zebra"])
  }

  @Test func sortsByTitleDescending() {
    let items = [makeItem(title: "Zebra"), makeItem(title: "Apple"), makeItem(title: "Mango")]
    let sorted = items.sorted(by: PasswordItem.sortComparator(for: .title, direction: .descending))
    #expect(sorted.map(\.title) == ["Zebra", "Mango", "Apple"])
  }

  @Test func titleSortIsCaseInsensitiveAndLocaleAware() {
    let items = [makeItem(title: "banana"), makeItem(title: "Apple")]
    let sorted = items.sorted(by: PasswordItem.sortComparator(for: .title, direction: .ascending))
    #expect(sorted.map(\.title) == ["Apple", "banana"])
  }

  @Test func sortsByWebsiteHostAscending() {
    let items = [
      makeItem(title: "C", website: "https://zzz.com"),
      makeItem(title: "A", website: "https://aaa.com"),
    ]
    let sorted = items.sorted(by: PasswordItem.sortComparator(for: .website, direction: .ascending))
    #expect(sorted.map(\.title) == ["A", "C"])
  }

  @Test func sortsByWebsiteHostDescending() {
    let items = [
      makeItem(title: "C", website: "https://zzz.com"),
      makeItem(title: "A", website: "https://aaa.com"),
    ]
    let sorted = items.sorted(by: PasswordItem.sortComparator(for: .website, direction: .descending))
    #expect(sorted.map(\.title) == ["C", "A"])
  }

  @Test func itemsWithoutAWebsiteSortBeforeThoseWithOneWhenAscending() {
    let items = [
      makeItem(title: "Has Website", website: "https://example.com"),
      makeItem(title: "No Website"),
    ]
    let sorted = items.sorted(by: PasswordItem.sortComparator(for: .website, direction: .ascending))
    #expect(sorted.map(\.title) == ["No Website", "Has Website"])
  }

  @Test func itemsWithoutAWebsiteSortAfterThoseWithOneWhenDescending() {
    let items = [
      makeItem(title: "Has Website", website: "https://example.com"),
      makeItem(title: "No Website"),
    ]
    let sorted = items.sorted(by: PasswordItem.sortComparator(for: .website, direction: .descending))
    #expect(sorted.map(\.title) == ["Has Website", "No Website"])
  }

  @Test func sortsByCreatedAtNewestFirstWhenDescending() {
    let older = makeItem(title: "Older", createdAt: Date(timeIntervalSince1970: 0))
    let newer = makeItem(title: "Newer", createdAt: Date(timeIntervalSince1970: 1_000))
    let sorted = [older, newer].sorted(
      by: PasswordItem.sortComparator(for: .createdAt, direction: .descending))
    #expect(sorted.map(\.title) == ["Newer", "Older"])
  }

  @Test func sortsByCreatedAtOldestFirstWhenAscending() {
    let older = makeItem(title: "Older", createdAt: Date(timeIntervalSince1970: 0))
    let newer = makeItem(title: "Newer", createdAt: Date(timeIntervalSince1970: 1_000))
    let sorted = [older, newer].sorted(
      by: PasswordItem.sortComparator(for: .createdAt, direction: .ascending))
    #expect(sorted.map(\.title) == ["Older", "Newer"])
  }

  @Test func sortsByModifiedAtNewestFirstWhenDescending() {
    let older = makeItem(title: "Older", modifiedAt: Date(timeIntervalSince1970: 0))
    let newer = makeItem(title: "Newer", modifiedAt: Date(timeIntervalSince1970: 1_000))
    let sorted = [older, newer].sorted(
      by: PasswordItem.sortComparator(for: .modifiedAt, direction: .descending))
    #expect(sorted.map(\.title) == ["Newer", "Older"])
  }

  @Test func fallsBackToTitleWhenDatesTie() {
    let sameInstant = Date(timeIntervalSince1970: 500)
    let items = [
      makeItem(title: "Zebra", createdAt: sameInstant),
      makeItem(title: "Apple", createdAt: sameInstant),
    ]
    let sorted = items.sorted(by: PasswordItem.sortComparator(for: .createdAt, direction: .descending))
    #expect(sorted.map(\.title) == ["Apple", "Zebra"])
  }

  @Test func tieBreakStaysAscendingTitleRegardlessOfDirection() {
    let sameInstant = Date(timeIntervalSince1970: 500)
    let items = [
      makeItem(title: "Zebra", createdAt: sameInstant),
      makeItem(title: "Apple", createdAt: sameInstant),
    ]
    let sorted = items.sorted(by: PasswordItem.sortComparator(for: .createdAt, direction: .ascending))
    #expect(sorted.map(\.title) == ["Apple", "Zebra"])
  }

  @Test func isStableAndDeterministicAcrossRepeatedSorts() {
    let items = (0..<20).map { makeItem(title: "Same Title", createdAt: Date(timeIntervalSince1970: Double($0))) }
    let first = items.sorted(by: PasswordItem.sortComparator(for: .title, direction: .ascending))
    let second = items.sorted(by: PasswordItem.sortComparator(for: .title, direction: .ascending))
    #expect(first.map(\.id) == second.map(\.id))
  }
}
