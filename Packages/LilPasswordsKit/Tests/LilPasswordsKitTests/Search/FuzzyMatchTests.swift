import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct FuzzyMatchTests {
  @Test func emptyQueryAlwaysMatchesWithZeroScore() {
    #expect(FuzzyMatch.score(query: "", in: "GitHub") == 0)
    #expect(FuzzyMatch.score(query: "", in: "") == 0)
  }

  @Test func emptyTargetNeverMatchesANonEmptyQuery() {
    #expect(FuzzyMatch.score(query: "gh", in: "") == nil)
  }

  @Test func nonSubsequenceDoesNotMatch() {
    #expect(FuzzyMatch.score(query: "xyz", in: "GitHub") == nil)
    #expect(FuzzyMatch.score(query: "hg", in: "GitHub") == nil)
  }

  @Test func isCaseAndDiacriticInsensitive() {
    #expect(FuzzyMatch.score(query: "GH", in: "github") != nil)
    #expect(FuzzyMatch.score(query: "cafe", in: "Café") != nil)
  }

  @Test func exactSubstringOutscoresAScatteredSubsequence() throws {
    let exact = try #require(FuzzyMatch.score(query: "git", in: "GitHub"))
    let scattered = try #require(FuzzyMatch.score(query: "gtu", in: "GitHub"))
    #expect(exact > scattered)
  }

  @Test func earlierOccurrenceOutscoresALaterOne() throws {
    let early = try #require(FuzzyMatch.score(query: "ex", in: "example.com"))
    let late = try #require(FuzzyMatch.score(query: "ex", in: "my example.com"))
    #expect(early > late)
  }

  @Test func wordBoundaryMatchOutscoresMidWordMatch() throws {
    let boundary = try #require(FuzzyMatch.score(query: "hub", in: "hub of hubs"))
    let midWord = try #require(FuzzyMatch.score(query: "hub", in: "github hub"))
    // The boundary match occurs earlier AND at a word boundary, so this also exercises the
    // position tie-break; what matters is that an earlier, boundary-aligned match wins.
    #expect(boundary > midWord)
  }

  @Test func consecutiveSubsequenceMatchesOutscoreGappedOnes() throws {
    // Neither query is an exact substring of "template", so both fall back to subsequence
    // scoring. "tpl" matches with its last two characters landing on adjacent target positions
    // (a contiguous run); "tml" matches with every character separated by a gap.
    let partiallyContiguous = try #require(FuzzyMatch.score(query: "tpl", in: "template"))
    let fullyGapped = try #require(FuzzyMatch.score(query: "tml", in: "template"))
    #expect(partiallyContiguous > fullyGapped)
  }
}
