import Foundation

/// How to launch `lilpass mcp`, shared by every 851-2432 "Connect Agents" configurator
/// (Claude Code, Codex, Cursor) so the command/args pair is defined exactly once.
public struct AgentMCPServerSpec: Sendable, Equatable {
  /// The server's name as it should appear in each tool's config (`mcp_servers.lilpass`,
  /// `mcpServers.lilpass`, etc.) — always ``LilPasswordsKit/cliName``.
  public let name: String
  /// The command to run — bare `lilpass`, resolved via `PATH`, matching 851-2432's assumption
  /// that the CLI has already been installed via the "Command Line Tool" section above these
  /// rows.
  public let command: String
  /// Arguments passed to `command` — just `mcp`.
  public let args: [String]

  public init(name: String, command: String, args: [String]) {
    self.name = name
    self.command = command
    self.args = args
  }

  /// The real spec every configurator uses in production: `lilpass mcp`.
  public static let lilpass = AgentMCPServerSpec(
    name: LilPasswordsKit.cliName,
    command: LilPasswordsKit.cliName,
    args: ["mcp"]
  )
}

/// Whether an agent's MCP config already points at ``AgentMCPServerSpec/lilpass``, as reported by
/// each configurator's `status()`.
public enum AgentMCPConnectionStatus: Sendable, Equatable {
  /// No entry for this server name found.
  case notConfigured
  /// An entry exists and matches `command`/`args` exactly.
  case configured
  /// An entry exists under this server name, but doesn't match — e.g. a different command or
  /// args, most likely hand-edited or pointed at a different `lilpass` path. Surfaced rather than
  /// silently overwritten so the UI can ask before "Add Automatically" replaces it.
  case configuredDifferently
}
