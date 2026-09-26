import Foundation
import LilPasswordsKit

/// Bridges the three "Connect Agents" rows (851-2432: Claude Code, Codex, Cursor) into an
/// `ObservableObject` for `AgentsSettingsView`.
///
/// Each agent is configured a different way under the hood — Claude Code through its own `claude`
/// CLI, Codex/Cursor by editing their config files directly (`CodexMCPConfigFile`/
/// `CursorMCPConfigFile`) — but this view model presents all three uniformly as an `Agent` case
/// with a status, a copyable snippet, and an optional "add automatically" action, so
/// `AgentsSettingsView` doesn't need to know the difference.
@MainActor
final class AgentConnectionsViewModel: ObservableObject {
  enum Agent: CaseIterable, Hashable, Identifiable {
    case claudeCode
    case codex
    case cursor

    var id: Self { self }

    var displayName: String {
      switch self {
      case .claudeCode: return "Claude Code"
      case .codex: return "Codex"
      case .cursor: return "Cursor"
      }
    }
  }

  @Published private(set) var statuses: [Agent: AgentMCPConnectionStatus] = [:]
  @Published private(set) var agentsAddingAutomatically: Set<Agent> = []
  @Published private(set) var lastErrorMessage: String?

  private let claudeCode: ClaudeCodeMCPConfigurator
  private let codex: CodexMCPConfigFile
  private let cursor: CursorMCPConfigFile
  private let cliInstaller: CLIInstaller

  init(
    claudeCode: ClaudeCodeMCPConfigurator = ClaudeCodeMCPConfigurator(),
    codex: CodexMCPConfigFile = CodexMCPConfigFile(),
    cursor: CursorMCPConfigFile = CursorMCPConfigFile(),
    cliInstaller: CLIInstaller = CLIInstaller(paths: CLIInstallViewModel.defaultInstallerPaths())
  ) {
    self.claudeCode = claudeCode
    self.codex = codex
    self.cursor = cursor
    self.cliInstaller = cliInstaller
  }

  /// The spec every configurator is actually asked about/told to write (851-2432): `command` is
  /// always resolved to an absolute path — preferring the installed symlink, falling back to the
  /// binary inside this app's own bundle — never the bare `lilpass` name, since GUI-launched agent
  /// processes (Cursor, the Codex desktop app, an IDE-launched Claude Code) spawn MCP servers
  /// without the user's shell `PATH` and would fail to find a bare command, especially for a
  /// `~/.local/bin` install. `alternateCommands` carries every other path that should still read
  /// as "connected," so toggling the CLI install location doesn't make an already-configured agent
  /// show up as "configured differently."
  private var resolvedSpec: AgentMCPServerSpec {
    let command = cliInstaller.resolvedCommandPath()
    let alternates = cliInstaller.acceptableCommandPaths().filter { $0 != command }
    return AgentMCPServerSpec(
      name: AgentMCPServerSpec.lilpass.name,
      command: command,
      args: AgentMCPServerSpec.lilpass.args,
      alternateCommands: alternates
    )
  }

  func refresh() {
    let spec = resolvedSpec
    statuses = [
      .claudeCode: claudeCode.status(for: spec),
      .codex: codex.status(for: spec),
      .cursor: cursor.status(for: spec),
    ]
  }

  func status(for agent: Agent) -> AgentMCPConnectionStatus {
    statuses[agent] ?? .notConfigured
  }

  /// The exact text a "Copy Setup" button for `agent` should put on the pasteboard.
  func snippet(for agent: Agent) -> String {
    let spec = resolvedSpec
    switch agent {
    case .claudeCode: return ClaudeCodeMCPConfigurator.copySnippet(for: spec)
    case .codex: return codex.snippet(for: spec)
    case .cursor: return cursor.snippet(for: spec)
    }
  }

  /// Whether "Add Automatically" should be offered for `agent` at all. Codex and Cursor can always
  /// create/edit their own config file, but Claude Code's automatic path shells out to `claude`
  /// itself, so it only makes sense when that binary is actually on `PATH`.
  func canAddAutomatically(for agent: Agent) -> Bool {
    switch agent {
    case .claudeCode: return claudeCode.isAvailable
    case .codex, .cursor: return true
    }
  }

  func isAddingAutomatically(_ agent: Agent) -> Bool {
    agentsAddingAutomatically.contains(agent)
  }

  func addAutomatically(for agent: Agent) async {
    agentsAddingAutomatically.insert(agent)
    defer { agentsAddingAutomatically.remove(agent) }
    let spec = resolvedSpec
    do {
      switch agent {
      case .claudeCode: try claudeCode.addAutomatically(spec: spec)
      case .codex: try codex.addAutomatically(spec: spec)
      case .cursor: try cursor.addAutomatically(spec: spec)
      }
      lastErrorMessage = nil
    } catch {
      lastErrorMessage = String(
        localized: "Couldn't set up \(agent.displayName) automatically. Try Copy Setup instead.")
    }
    refresh()
  }
}
