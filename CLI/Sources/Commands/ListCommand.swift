import ArgumentParser
import LilPasswordsKit
import LilpassCore

struct ListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List vault items. Never prints passwords, notes, or TOTP codes."
  )

  @Option(name: .long, help: "Only list items in this group/category (case-insensitive).")
  var category: String?

  @OptionGroup var jsonOutput: JSONOutputOptions

  func run() async throws {
    let items = try await LilpassCommands.list(client: AgentClient(), category: category)
    Output.print(items, asJSON: jsonOutput.json) { items in
      guard !items.isEmpty else {
        print("no items")
        return
      }
      for item in items {
        print(Self.line(for: item))
      }
    }
  }

  /// Shared with `SearchCommand`'s plain-text rendering — `list` and `search` both return
  /// `[ItemSummary]` and print it the same way.
  static func line(for item: ItemSummary) -> String {
    var parts = [item.title]
    if let group = item.group { parts.append("[\(group)]") }
    if let website = item.websites.first { parts.append(website) }
    if item.hasTOTP { parts.append("(TOTP)") }
    return parts.joined(separator: "  ")
  }
}
