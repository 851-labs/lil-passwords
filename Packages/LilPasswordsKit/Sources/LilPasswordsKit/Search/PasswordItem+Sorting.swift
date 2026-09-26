import Foundation

/// The fields the item list (851-2414) can be sorted by, via the sort-options menu.
public enum PasswordItemSortField: String, CaseIterable, Sendable {
  case title
  case createdAt
  case modifiedAt
  case website
}

extension PasswordItem {
  /// A comparator for `field`, suitable for `Array.sorted(by:)`, with deterministic tie-breaking
  /// so equal-looking rows don't jitter between re-sorts: title/website order ties fall back to
  /// title, then to `id`, and title itself falls back to `id`.
  ///
  /// `title` and `website` sort ascending (A→Z, matching Finder/Contacts); `createdAt` and
  /// `modifiedAt` sort descending (newest first), since that's what's usually useful when
  /// browsing by date.
  public static func sortComparator(for field: PasswordItemSortField) -> (PasswordItem, PasswordItem) -> Bool {
    switch field {
    case .title:
      return { a, b in orderedByTitle(a, b) }
    case .website:
      return { a, b in
        let lhs = a.websites.first?.host ?? ""
        let rhs = b.websites.first?.host ?? ""
        switch lhs.localizedStandardCompare(rhs) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return orderedByTitle(a, b)
        }
      }
    case .createdAt:
      return { a, b in a.createdAt == b.createdAt ? orderedByTitle(a, b) : a.createdAt > b.createdAt }
    case .modifiedAt:
      return { a, b in a.modifiedAt == b.modifiedAt ? orderedByTitle(a, b) : a.modifiedAt > b.modifiedAt }
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
