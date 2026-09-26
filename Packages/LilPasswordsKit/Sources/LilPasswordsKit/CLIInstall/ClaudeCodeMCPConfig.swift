import Foundation

/// The seam `ClaudeCodeMCPConfigurator` calls through, so tests can script `claude`'s behavior
/// instead of ever shelling out to a real binary — the same reasoning `HelperAgentRegistering`
/// documents for keeping `SMAppService` behind a protocol.
public protocol ClaudeCodeCLIRunning: Sendable {
  /// The absolute path to the `claude` binary, or `nil` if it isn't on `PATH`.
  func locate() -> String?
  /// Runs `claude` with `arguments`, returning combined stdout+stderr. Throws if the binary can't
  /// be launched at all; a non-zero exit is *not* thrown, just reflected in the returned text (the
  /// callers here only ever grep/act on it either way).
  func run(_ arguments: [String]) throws -> String
}

/// The real conformer: finds `claude` on `PATH` via `/usr/bin/env -S which claude` and runs it
/// with `Process`.
public struct SystemClaudeCodeCLI: ClaudeCodeCLIRunning {
  public init() {}

  public func locate() -> String? {
    guard let output = try? runProcess(executable: "/usr/bin/which", arguments: ["claude"]) else { return nil }
    let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
  }

  public func run(_ arguments: [String]) throws -> String {
    guard let binary = locate() else {
      throw ClaudeCodeMCPConfigurator.ConfigurationError.claudeNotFound
    }
    return try runProcess(executable: binary, arguments: arguments)
  }

  private func runProcess(executable: String, arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
  }
}

/// Detects and configures Claude Code's MCP connection to `lilpass mcp` (851-2432), by shelling
/// out to the user's own `claude` binary rather than editing a config file directly — unlike
/// Codex/Cursor, Claude Code's own `claude mcp add`/`claude mcp list` commands are the documented,
/// stable interface for this, and its underlying config file/format isn't.
public struct ClaudeCodeMCPConfigurator: Sendable {
  public enum ConfigurationError: Error, Equatable {
    /// `claude` isn't on `PATH` — "Add Automatically" isn't offered in this case; only "Copy
    /// Setup" is.
    case claudeNotFound
  }

  private let cli: any ClaudeCodeCLIRunning

  public init(cli: any ClaudeCodeCLIRunning = SystemClaudeCodeCLI()) {
    self.cli = cli
  }

  /// The exact command the "Copy Setup" button copies — run manually in any terminal. Deliberately
  /// without `--scope user` (unlike ``addAutomatically(spec:)`` below): a manually-run command
  /// defaults to whatever scope makes sense for the terminal the user is already in (e.g. a
  /// project directory), whereas the automatic path has no such context and explicitly asks for
  /// the user-wide scope so it's available everywhere.
  public static func copySnippet(for spec: AgentMCPServerSpec = .lilpass) -> String {
    "claude mcp add \(spec.name) -- \(([spec.command] + spec.args).joined(separator: " "))"
  }

  /// Whether `claude` is on `PATH` at all — gates whether "Add Automatically" is offered.
  public var isAvailable: Bool { cli.locate() != nil }

  /// Runs `claude mcp list` and checks whether `spec`'s name shows up. `claude` reports the
  /// configured command/args in that listing too, but its exact text format isn't a stable
  /// contract the way `mcp add`/`mcp list` existing-or-not is, so this only distinguishes
  /// "configured" from "not configured" — never `.configuredDifferently`.
  public func status(for spec: AgentMCPServerSpec = .lilpass) -> AgentMCPConnectionStatus {
    guard isAvailable, let output = try? cli.run(["mcp", "list"]) else { return .notConfigured }
    return output.contains(spec.name) ? .configured : .notConfigured
  }

  /// `claude mcp add --scope user <name> -- <command> <args...>`. Throws
  /// ``ConfigurationError/claudeNotFound`` if `claude` isn't on `PATH`.
  public func addAutomatically(spec: AgentMCPServerSpec = .lilpass) throws {
    guard isAvailable else { throw ConfigurationError.claudeNotFound }
    _ = try cli.run(["mcp", "add", "--scope", "user", spec.name, "--"] + [spec.command] + spec.args)
  }
}
