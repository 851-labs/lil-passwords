import ArgumentParser
import LilPasswordsKit
import LilpassCore
import LilpassMCP
import MCP

/// `lilpass mcp`: runs `lilpass` as a stdio MCP server (851-2431), so an MCP-capable agent can call
/// `list_passwords`, `search_passwords`, `get_password`, `get_verification_code`, and
/// `generate_password` directly instead of shelling out to the other subcommands.
///
/// Like every other subcommand, this is thin: `LilpassMCP.makeServer(client:)` owns all the tool
/// definitions and dispatch logic (unit-tested in `LilpassMCPTests` against an in-process
/// `AgentServer` + `InMemoryVaultStore`, the same harness `LilpassCoreTests` uses). This command's
/// only job is wiring that server to stdio and running it until the client disconnects.
struct McpCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mcp",
    abstract: "Run lilpass as a stdio MCP server."
  )

  func run() async throws {
    let server = await LilpassMCP.makeServer(client: AgentClient())
    try await server.start(transport: StdioTransport())
    await server.waitUntilCompleted()
  }
}
