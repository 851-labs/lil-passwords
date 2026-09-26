import Foundation

/// Which-items-show-where logic for the sidebar's Codes and Deleted categories (851-2418,
/// 851-2420), plus the day-math ordering the Deleted view sorts by. Pulled out as plain sequence
/// operations (rather than left inline in the AppKit view controllers that use them) so it's
/// exercised by `swift test` instead of only by manual tophat.
extension Sequence where Element == PasswordItem {
  /// Every item that hasn't been moved to Recently Deleted.
  public func nonDeleted() -> [PasswordItem] {
    filter { $0.deletedAt == nil }
  }

  /// Every non-deleted item that has a verification code — the Codes sidebar category.
  public func withVerificationCode() -> [PasswordItem] {
    filter { $0.deletedAt == nil && $0.totpURI != nil }
  }

  /// Every item currently in Recently Deleted — the Deleted sidebar category.
  public func recentlyDeleted() -> [PasswordItem] {
    filter { $0.deletedAt != nil }
  }
}

extension Array where Element == PasswordItem {
  /// Sorted soonest-to-expire first (ascending ``PasswordItem/daysRemaining(now:)``), the order
  /// the Deleted view (851-2420) lists items in — items about to be purged for good surface at
  /// the top instead of getting buried. Items tie-break by title, then `id`, matching
  /// `PasswordItem.sortComparator(for: .title)`'s own tie-breaking so re-sorts stay stable.
  ///
  /// An item with no ``PasswordItem/deletedAt`` (so `daysRemaining` is `nil`) sorts last, as if it
  /// had the maximum possible number of days remaining — this function is only meaningful for
  /// already-``recentlyDeleted()``-filtered input, but shouldn't crash or reorder unexpectedly if
  /// handed something else.
  public func sortedByDaysRemaining(now: Date = Date()) -> [PasswordItem] {
    sorted { a, b in
      let daysA = a.daysRemaining(now: now) ?? .max
      let daysB = b.daysRemaining(now: now) ?? .max
      guard daysA != daysB else {
        switch a.title.localizedStandardCompare(b.title) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.id.uuidString < b.id.uuidString
        }
      }
      return daysA < daysB
    }
  }
}
