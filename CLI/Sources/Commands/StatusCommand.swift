import ArgumentParser
import LilPasswordsKit
import LilpassCore

struct StatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Show whether the vault is unlocked and whether agent access is enabled."
  )

  @OptionGroup var jsonOutput: JSONOutputOptions

  func run() async throws {
    let status = try await LilpassCommands.status(client: AgentEndpoint.makeClient())
    Output.print(status, asJSON: jsonOutput.json) { status in
      print("locked: \(status.locked)")
      print("agentAccessEnabled: \(status.agentAccessEnabled)")
    }
  }
}
