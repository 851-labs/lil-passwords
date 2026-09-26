import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct PasswordItemSearchTests {
  private func makeItem(
    title: String,
    usernames: [String] = [],
    websites: [URL] = []
  ) -> PasswordItem {
    PasswordItem(title: title, usernames: usernames, websites: websites)
  }

  @Test func matchesByTitle() {
    let item = makeItem(title: "GitHub")
    #expect(item.searchScore(for: "git") != nil)
  }

  @Test func matchesByUsername() {
    let item = makeItem(title: "GitHub", usernames: ["octocat"])
    #expect(item.searchScore(for: "octo") != nil)
  }

  @Test func matchesByWebsiteHost() {
    let item = makeItem(title: "GitHub", websites: [URL(string: "https://github.com")!])
    #expect(item.searchScore(for: "github.com") != nil)
  }

  @Test func returnsNilWhenNothingMatches() {
    let item = makeItem(title: "GitHub", usernames: ["octocat"], websites: [URL(string: "https://github.com")!])
    #expect(item.searchScore(for: "zzz") == nil)
  }

  @Test func emptyQueryMatchesEverythingWithZeroScore() {
    let item = makeItem(title: "GitHub")
    #expect(item.searchScore(for: "") == 0)
  }

  @Test func ignoresEmptyUsernameStrings() {
    let item = makeItem(title: "GitHub", usernames: [""])
    // An empty username shouldn't crash or spuriously match; the title still matches on its own.
    #expect(item.searchScore(for: "git") != nil)
  }

  @Test func titleMatchOutranksUsernameMatchOfEqualQuality() throws {
    let titleMatch = makeItem(title: "octocat", usernames: ["nobody"])
    let usernameMatch = makeItem(title: "Example", usernames: ["octocat"])

    let titleScore = try #require(titleMatch.searchScore(for: "octocat"))
    let usernameScore = try #require(usernameMatch.searchScore(for: "octocat"))
    #expect(titleScore > usernameScore)
  }

  @Test func usernameMatchOutranksWebsiteMatchOfEqualQuality() throws {
    let usernameMatch = makeItem(
      title: "Example", usernames: ["github"], websites: [URL(string: "https://nobody.com")!])
    let websiteMatch = makeItem(
      title: "Example", usernames: ["nobody"], websites: [URL(string: "https://github.com")!])

    let usernameScore = try #require(usernameMatch.searchScore(for: "github"))
    let websiteScore = try #require(websiteMatch.searchScore(for: "github"))
    #expect(usernameScore > websiteScore)
  }

  @Test func titleSectionKeyUsesUppercasedFirstLetter() {
    #expect(makeItem(title: "github").titleSectionKey == "G")
    #expect(makeItem(title: "Amazon").titleSectionKey == "A")
  }

  @Test func titleSectionKeyFoldsDiacritics() {
    #expect(makeItem(title: "Éclair").titleSectionKey == "E")
  }

  @Test func titleSectionKeyFallsBackToHashForNonLetters() {
    #expect(makeItem(title: "1Password").titleSectionKey == "#")
    #expect(makeItem(title: "42").titleSectionKey == "#")
    #expect(makeItem(title: "").titleSectionKey == "#")
    #expect(makeItem(title: "   ").titleSectionKey == "#")
  }

  @Test func titleSectionKeyIgnoresLeadingWhitespace() {
    #expect(makeItem(title: "  Zebra").titleSectionKey == "Z")
  }

  @Test func matchesHostIgnoresSchemeAndPath() {
    let item = makeItem(title: "Netflix", websites: [URL(string: "https://www.netflix.com/browse")!])
    #expect(item.matchesHost(of: URL(string: "https://netflix.com/login")!))
  }

  @Test func matchesHostIsCaseInsensitive() {
    let item = makeItem(title: "Netflix", websites: [URL(string: "https://Netflix.com")!])
    #expect(item.matchesHost(of: URL(string: "https://NETFLIX.COM")!))
  }

  @Test func matchesHostReturnsFalseForUnrelatedSites() {
    let item = makeItem(title: "Netflix", websites: [URL(string: "https://netflix.com")!])
    #expect(item.matchesHost(of: URL(string: "https://example.com")!) == false)
  }

  @Test func matchesHostReturnsFalseWhenItemHasNoWebsites() {
    let item = makeItem(title: "Netflix")
    #expect(item.matchesHost(of: URL(string: "https://netflix.com")!) == false)
  }
}
