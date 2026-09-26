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

  init(
    claudeCode: ClaudeCodeMCPConfigurator = ClaudeCodeMCPConfigurator(),
    codex: CodexMCPConfigFile = CodexMCPConfigFile(),
    cursor: CursorMCPConfigFile = CursorMCPConfigFile()
  ) {
    self.claudeCode = claudeCode
    self.codex = codex
    self.cursor = cursor
  }

  func refresh() {
    statuses = [
      .claudeCode: claudeCode.status(),
      .codex: codex.status(),
      .cursor: cursor.status(),
    ]
  }

  func status(for agent: Agent) -> AgentMCPConnectionStatus {
    statuses[agent] ?? .notConfigured
  }

  /// The exact text a "Copy Setup" button for `agent` should put on the pasteboard.
  func snippet(for agent: Agent) -> String {
    switch agent {
    case .claudeCode: return ClaudeCodeMCPConfigurator.copySnippet()
    case .codex: return codex.snippet()
    case .cursor: return cursor.snippet()
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
    do {
      switch agent {
      case .claudeCode: try claudeCode.addAutomatically()
      case .codex: try codex.addAutomatically()
      case .cursor: try cursor.addAutomatically()
      }
      lastErrorMessage = nil
    } catch {
      lastErrorMessage = "Couldn't set up \(agent.displayName) automatically. Try Copy Setup instead."
    }
    refresh()
  }
}
