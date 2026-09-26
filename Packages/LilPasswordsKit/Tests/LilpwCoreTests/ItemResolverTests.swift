import Foundation
import LilPasswordsKit
import LilpwCore
import Testing

@Suite struct ItemResolverTests {
  @Test func resolvesByExactId() throws {
    let item = makeTestItem()
    let other = makeTestItem(title: "Mail")
    let resolved = try ItemResolver.resolve(item.id.uuidString, in: [item, other])
    #expect(resolved.id == item.id)
  }

  @Test func unknownIdIsNotFoundEvenIfATitleHappensToCollide() {
    let item = makeTestItem()
    #expect(throws: LilpwError.self) {
      _ = try ItemResolver.resolve(UUID().uuidString, in: [item])
    }
  }

  @Test func resolvesByExactTitleCaseInsensitively() throws {
    let item = makeTestItem(title: "GitHub")
    let resolved = try ItemResolver.resolve("github", in: [item])
    #expect(resolved.id == item.id)
  }

  @Test func doesNotMatchATitleSubstring() {
    let item = makeTestItem(title: "GitHub Enterprise")
    #expect(throws: LilpwError.self) {
      _ = try ItemResolver.resolve("github", in: [item])
    }
  }

  @Test func resolvesByWebsiteDomainCaseInsensitively() throws {
    let item = makeTestItem(title: "GH", websites: [URL(string: "https://GitHub.com/login")!])
    let resolved = try ItemResolver.resolve("github.com", in: [item])
    #expect(resolved.id == item.id)
  }

  @Test func ambiguousTitleListsEveryCandidate() {
    let a = makeTestItem(title: "GitHub Work")
    let b = makeTestItem(title: "GitHub Work")
    do {
      _ = try ItemResolver.resolve("github work", in: [a, b])
      Issue.record("expected .ambiguous")
    } catch let error as LilpwError {
      #expect(error.exitCode == .ambiguous)
      #expect(error.message.contains(a.id.uuidString))
      #expect(error.message.contains(b.id.uuidString))
    } catch {
      Issue.record("expected LilpwError, got \(error)")
    }
  }

  @Test func noMatchIsNotFound() {
    do {
      _ = try ItemResolver.resolve("nonexistent", in: [makeTestItem()])
      Issue.record("expected .notFound")
    } catch let error as LilpwError {
      #expect(error.exitCode == .notFound)
    } catch {
      Issue.record("expected LilpwError, got \(error)")
    }
  }
}
