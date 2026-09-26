import Foundation

/// How to launch `lilpass mcp`, shared by every 851-2432 "Connect Agents" configurator
/// (Claude Code, Codex, Cursor) so the command/args pair is defined exactly once.
public struct AgentMCPServerSpec: Sendable, Equatable {
  /// The server's name as it should appear in each tool's config (`mcp_servers.lilpass`,
  /// `mcpServers.lilpass`, etc.) — always ``LilPasswordsKit/cliName``.
  public let name: String
  /// The command to run. Production callers should always resolve this to an absolute path
  /// (``CLIInstaller/resolvedCommandPath()``) rather than the bare `lilpass` name: GUI-launched
  /// agent processes (Cursor, the Codex desktop app, an IDE-launched Claude Code) spawn MCP
  /// servers without the user's shell `PATH`, so a bare command name fails to launch, especially
  /// for a `~/.local/bin` install. `.lilpass` below still defaults to the bare name for tests that
  /// only care about the text-editing logic, not path resolution.
  public let command: String
  /// Arguments passed to `command` — just `mcp`.
  public let args: [String]
  /// Other command strings that should also count as "this is lilpass" when checking whether an
  /// existing config already points at us (``AgentMCPConnectionStatus/configured``) — typically
  /// the app-bundle fallback path alongside the currently-installed symlink path, so a config
  /// written against either one doesn't show as ``AgentMCPConnectionStatus/configuredDifferently``
  /// just because the CLI install location changed since. Never used when *writing* a new
  /// snippet/block/entry — only `command` is ever written.
  public let alternateCommands: [String]

  public init(name: String, command: String, args: [String], alternateCommands: [String] = []) {
    self.name = name
    self.command = command
    self.args = args
    self.alternateCommands = alternateCommands
  }

  /// Whether `command` should be treated as a match for this spec — either the primary `command`
  /// or one of `alternateCommands`.
  public func matches(command: String) -> Bool {
    command == self.command || alternateCommands.contains(command)
  }

  /// The bare-name spec every configurator defaults to — mostly useful for tests that only
  /// exercise text-editing logic. Production call sites should build a spec whose `command` is
  /// ``CLIInstaller/resolvedCommandPath()`` instead.
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
