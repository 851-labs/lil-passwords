import Foundation

/// The fields the item list (851-2414) can be sorted by, via the sort-options menu.
public enum PasswordItemSortField: String, CaseIterable, Sendable {
  case title
  case createdAt
  case modifiedAt
  case website
}

/// Which way a ``PasswordItemSortField`` orders items, chosen independently of the field itself
/// from the sort menu's second section (851-2463) and persisted in `AppSettings`.
public enum SortDirection: String, CaseIterable, Sendable {
  case ascending
  case descending
}

extension PasswordItem {
  /// A comparator for `field`/`direction`, suitable for `Array.sorted(by:)`. `direction` only
  /// flips `field`'s own ordering — ties always fall back to title (A→Z), then `id`, regardless
  /// of `direction`, so switching Ascending/Descending reorders by the chosen field without also
  /// scrambling the secondary tie-break a user never asked to reverse.
  public static func sortComparator(
    for field: PasswordItemSortField,
    direction: SortDirection
  ) -> (PasswordItem, PasswordItem) -> Bool {
    let primaryOrder = primaryOrdering(for: field)
    return { a, b in
      switch primaryOrder(a, b) {
      case .orderedAscending: return direction == .ascending
      case .orderedDescending: return direction == .descending
      case .orderedSame: return orderedByTitle(a, b)
      }
    }
  }

  /// `field`'s own natural ordering (title/website A→Z, date fields oldest-first), independent of
  /// `direction` and before the title/id tie-break is applied.
  private static func primaryOrdering(for field: PasswordItemSortField) -> (PasswordItem, PasswordItem) ->
    ComparisonResult
  {
    switch field {
    case .title:
      return { a, b in a.title.localizedStandardCompare(b.title) }
    case .website:
      return { a, b in
        let lhs = a.websites.first?.host ?? ""
        let rhs = b.websites.first?.host ?? ""
        return lhs.localizedStandardCompare(rhs)
      }
    case .createdAt:
      return { a, b in
        a.createdAt == b.createdAt ? .orderedSame : (a.createdAt < b.createdAt ? .orderedAscending : .orderedDescending)
      }
    case .modifiedAt:
      return { a, b in
        a.modifiedAt == b.modifiedAt
          ? .orderedSame : (a.modifiedAt < b.modifiedAt ? .orderedAscending : .orderedDescending)
      }
    }
  }

  private static func orderedByTitle(_ a: PasswordItem, _ b: PasswordItem) -> Bool {
    switch a.title.localizedStandardCompare(b.title) {
    case .orderedAscending: return true
    case .orderedDescending: return false
    case .orderedSame: return a.id.uuidString < b.id.uuidString
    }
  }
}
