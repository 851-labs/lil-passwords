import Foundation

extension PasswordItem {
  /// Best fuzzy-match score for `query` across this item's title, usernames, and website hosts,
  /// or `nil` if none of them match at all. Used to rank item-list search results (851-2417);
  /// title matches are weighted highest, since that's what a user is most often thinking of when
  /// they start typing, and usernames a bit higher than website hosts.
  public func searchScore(for query: String) -> Double? {
    var best: Double?
    func consider(_ text: String, weight: Double) {
      guard let score = FuzzyMatch.score(query: query, in: text) else { return }
      let weighted = score * weight
      if best == nil || weighted > best! {
        best = weighted
      }
    }

    consider(title, weight: 1.2)
    for username in usernames where !username.isEmpty {
      consider(username, weight: 1.0)
    }
    for website in websites {
      consider(website.host ?? website.absoluteString, weight: 0.9)
    }
    return best
  }

  /// Alphabetical section key for grouping the item list when sorted by title (851-2414): the
  /// title's first character, uppercased and diacritic-folded, or `"#"` if the title doesn't
  /// start with a letter (digits, symbols, emoji, or an empty title) — matching how Contacts and
  /// Apple Passwords bucket names into section headers.
  public var titleSectionKey: String {
    guard let first = title.trimmingCharacters(in: .whitespacesAndNewlines).first, first.isLetter else {
      return "#"
    }
    return String(first).folding(options: .diacriticInsensitive, locale: nil).uppercased()
  }
}
