import Foundation

/// A minimal fuzzy string matcher used to rank item-list search results: does `query` match
/// `target` as a (possibly non-contiguous) subsequence, and if so, how good is the match?
///
/// This is deliberately simple — no full Smith-Waterman-style alignment — it just needs to make
/// "gh" find "GitHub" and rank an exact substring above a scattered one the way a user expects,
/// not to be a general-purpose fuzzy-finder library.
public enum FuzzyMatch {
  /// Scores `query` against `target`, case- and diacritic-insensitive. Returns `nil` if `target`
  /// is non-empty and doesn't contain every character of `query`, in order (an empty `query`
  /// always matches, with a score of `0`, since "no search text" means "show everything").
  ///
  /// Higher scores are better matches; the scale has no fixed bound, only relative ordering.
  /// Scoring favors, in order: an exact substring match over a scattered one, an earlier
  /// occurrence over a later one, a match starting at a word boundary, and consecutive matched
  /// characters over gapped ones.
  public static func score(query: String, in target: String) -> Double? {
    let foldedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    let foldedTarget = target.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)

    guard !foldedQuery.isEmpty else { return 0 }
    guard !foldedTarget.isEmpty else { return nil }

    if let range = foldedTarget.range(of: foldedQuery) {
      // An exact substring is always the best possible match. Rank an occurrence at (or right
      // after a non-letter before) the start higher than one buried mid-word, and an earlier
      // position higher than a later one.
      let position = foldedTarget.distance(from: foldedTarget.startIndex, to: range.lowerBound)
      let atWordBoundary =
        range.lowerBound == foldedTarget.startIndex
        || !foldedTarget[foldedTarget.index(before: range.lowerBound)].isLetter
      return 1_000 - Double(position) + (atWordBoundary ? 50 : 0)
    }

    // Fall back to subsequence matching: every query character must appear in target, in order,
    // possibly with gaps. Greedily match each query character to the earliest possible position
    // at or after the previous match, tracking whether each match immediately follows the last
    // one — a contiguous run of matched characters scores much higher than the same characters
    // scattered across the string.
    var searchStart = foldedTarget.startIndex
    var previousMatchEnd: String.Index?
    var matchedFirstCharacterAtStart = false
    var score = 0.0

    for (index, character) in foldedQuery.enumerated() {
      guard let matchIndex = foldedTarget[searchStart...].firstIndex(of: character) else { return nil }

      if index == 0, matchIndex == foldedTarget.startIndex {
        matchedFirstCharacterAtStart = true
      }
      score += (previousMatchEnd == matchIndex) ? 6 : 1

      previousMatchEnd = foldedTarget.index(after: matchIndex)
      searchStart = previousMatchEnd!
    }

    return score + (matchedFirstCharacterAtStart ? 10 : 0)
  }
}
