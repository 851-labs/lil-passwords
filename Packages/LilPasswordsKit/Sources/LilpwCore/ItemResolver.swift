import Foundation
import LilPasswordsKit

/// Resolves a `lilpw` command-line identifier (`lilpw get <item>`, `lilpw totp <item>`, a
/// `lilpw://<item>/<field>` reference's host, etc.) to a single ``PasswordItem``.
///
/// This is deliberately its own, client-side resolution rule — distinct from
/// `AgentRequest.getItem(.query(_:))`'s free-text search over title/usernames/website hosts (see
/// `AgentServer.resolve(_:)`) — because 851-2430 specifically asks for id-or-exact-title-or-website
/// -domain matching with a candidate list on ambiguity, not `VaultStoring.items(matching:)`'s looser
/// substring search. `lilpw search <q>` still uses the looser search directly via
/// `AgentClient.search(_:)`.
public enum ItemResolver {
  /// - Parameters:
  ///   - identifier: An item's `id` (as a UUID string), its exact title (case-insensitive), or a
  ///     website's host (case-insensitive), e.g. `github.com`.
  ///   - items: Every candidate to resolve against — typically `AgentClient.list()`'s result.
  /// - Throws: `LilpwError` with exit code `.notFound` if nothing matches, or `.ambiguous` (listing
  ///   every candidate's title and id) if more than one item matches the same strategy.
  public static func resolve(_ identifier: String, in items: [PasswordItem]) throws -> PasswordItem {
    if let id = UUID(uuidString: identifier) {
      if let match = items.first(where: { $0.id == id }) {
        return match
      }
      throw notFound(identifier)
    }

    let normalized = identifier.lowercased()

    let titleMatches = items.filter { $0.title.lowercased() == normalized }
    if !titleMatches.isEmpty {
      return try single(titleMatches, identifier: identifier)
    }

    let domainMatches = items.filter { item in
      item.websites.contains { website in website.host?.lowercased() == normalized }
    }
    if !domainMatches.isEmpty {
      return try single(domainMatches, identifier: identifier)
    }

    throw notFound(identifier)
  }

  private static func single(_ matches: [PasswordItem], identifier: String) throws -> PasswordItem {
    guard matches.count == 1 else {
      let candidates = matches.map { "\($0.title) (\($0.id.uuidString))" }.joined(separator: ", ")
      throw LilpwError(exitCode: .ambiguous, message: "\"\(identifier)\" matches more than one item: \(candidates)")
    }
    return matches[0]
  }

  private static func notFound(_ identifier: String) -> LilpwError {
    LilpwError(exitCode: .notFound, message: "no item matches \"\(identifier)\"")
  }
}
