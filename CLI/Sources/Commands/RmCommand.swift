import ArgumentParser
import LilPasswordsKit
import LilpassCore

struct RmCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rm",
    abstract: "Remove an item from the vault.",
    discussion: """
      Soft-deletes: the item moves to Recently Deleted, exactly like deleting it from the app —
      there is no permanent-delete request an agent can reach. Requires agent write access
      (851-2433).
      """
  )

  @Argument(help: "An item's id, exact title (case-insensitive), or website domain.")
  var item: String

  @OptionGroup var jsonOutput: JSONOutputOptions

  func run() async throws {
    let removed = try await LilpassCommands.remove(client: AgentClient(), identifier: item)
    Output.print(removed, asJSON: jsonOutput.json) { summary in
      print("removed \"\(summary.title)\" (\(summary.id))")
    }
  }
}
