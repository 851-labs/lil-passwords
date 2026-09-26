import ArgumentParser
import LilPasswordsKit
import LilpassCore

struct SearchCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "search",
    abstract: "Search vault items by title, username, or website. Never prints secrets."
  )

  @Argument(help: "The free-text query to search for.")
  var query: String

  @OptionGroup var jsonOutput: JSONOutputOptions

  func run() async throws {
    let items = try await LilpassCommands.search(client: AgentClient(), query: query)
    Output.print(items, asJSON: jsonOutput.json) { items in
      guard !items.isEmpty else {
        print("no items")
        return
      }
      for item in items {
        print(ListCommand.line(for: item))
      }
    }
  }
}
