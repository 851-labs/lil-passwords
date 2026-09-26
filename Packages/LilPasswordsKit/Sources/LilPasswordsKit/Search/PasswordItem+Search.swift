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

  /// Whether any of this item's ``websites`` shares a host with `url` — used by the menu bar
  /// extra's "Suggested" section (851-2425) to match the frontmost browser's current site against
  /// saved items. Host comparison is case-insensitive and ignores a leading "www." on either
  /// side, so `https://www.netflix.com` and `https://netflix.com` count as the same site.
  public func matchesHost(of url: URL) -> Bool {
    guard let targetHost = url.host?.strippingLeadingWWW else { return false }
    return websites.contains { $0.host?.strippingLeadingWWW == targetHost }
  }

  /// Same host comparison as ``matchesHost(of:)``, but from a raw host/domain string rather than a
  /// full `URL` — 851-2441's AutoFill credential provider receives `ASCredentialServiceIdentifier`
  /// values that are typically bare domains (e.g. `"netflix.com"`), not `URL`s: `URL(string:)` on a
  /// scheme-less string like that leaves `.host` `nil` (the whole string parses as a path), so
  /// `matchesHost(of:)` itself can't be reused directly for this caller.
  public func matchesHost(ofServiceIdentifier identifier: String) -> Bool {
    let targetHost = identifier.strippingLeadingWWW
    return websites.contains { $0.host?.strippingLeadingWWW == targetHost }
  }
}

extension String {
  /// Lowercases and drops a leading `"www."` label, e.g. `"WWW.Amazon.com"` → `"amazon.com"`.
  /// Used both for host-equality comparisons in this file and, since it's just a `"www."`
  /// strip rather than a full public-suffix-list/eTLD+1 computation, for display text that wants
  /// the same "closest thing to a registrable domain" a person actually types — see
  /// `PasskeyMetadata.displayTitle` (851-2442). Not `fileprivate` so both can share it.
  var strippingLeadingWWW: String {
    let lowercased = lowercased()
    return lowercased.hasPrefix("www.") ? String(lowercased.dropFirst(4)) : lowercased
  }
}
