import ArgumentParser
import LilPasswordsKit
import LilpwCore

struct TotpCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "totp",
    abstract: "Print a current TOTP code for an item."
  )

  @Argument(help: "An item's id, exact title (case-insensitive), or website domain.")
  var item: String

  @OptionGroup var jsonOutput: JSONOutputOptions

  func run() async throws {
    let result = try await LilpwCommands.totp(client: AgentClient(), identifier: item)
    Output.print(result, asJSON: jsonOutput.json) { result in print(result.code) }
  }
}
