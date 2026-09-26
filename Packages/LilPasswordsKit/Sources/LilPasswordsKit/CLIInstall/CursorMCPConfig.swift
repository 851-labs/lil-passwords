import Foundation

/// JSON editing for Cursor's `~/.cursor/mcp.json` (851-2432): a top-level `mcpServers` object,
/// keyed by server name.
///
/// Unlike ``CodexMCPConfigEditor`` (hand-rolled text editing, since there's no TOML library in
/// this package), this one goes through real `JSONSerialization` — Cursor's config is plain JSON,
/// so there's no reason not to parse it properly. `upsert`/`status` only ever touch the single
/// `mcpServers.<name>` entry they own; every other key in the file (including other servers under
/// `mcpServers`) round-trips untouched.
public enum CursorMCPConfigEditor {
  public enum ConfigError: Error, Equatable {
    /// `contents` was non-empty but not a valid JSON object — refuse to guess rather than risk
    /// clobbering a file the user hand-edited into a broken state.
    case invalidJSON
  }

  /// The exact `"<name>": { ... }` entry a "Copy Setup" action should put on the pasteboard, meant
  /// to be pasted inside the file's existing `mcpServers` object. Built by hand (not derived from
  /// `JSONSerialization`'s own top-level-object output) so the snippet is exactly the fragment a
  /// user pastes, with no outer braces to strip.
  public static func snippetEntry(for spec: AgentMCPServerSpec) -> String {
    let args = spec.args.map { "\"\($0)\"" }.joined(separator: ", ")
    return """
      "\(spec.name)": {
        "command": "\(spec.command)",
        "args": [\(args)]
      }
      """
  }

  /// Returns `contents` (a full `mcp.json`, or empty for "file doesn't exist yet") with `spec`'s
  /// entry inserted or replaced under `mcpServers`. Idempotent, and leaves every other key
  /// (including other servers) untouched.
  public static func upsert(spec: AgentMCPServerSpec, in contents: String) throws -> String {
    var root = try parseObject(contents)
    var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
    servers[spec.name] = serverEntry(for: spec)
    root["mcpServers"] = servers
    guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
      let string = String(data: data, encoding: .utf8)
    else {
      throw ConfigError.invalidJSON
    }
    return string
  }

  public static func status(of spec: AgentMCPServerSpec, in contents: String) -> AgentMCPConnectionStatus {
    guard let root = try? parseObject(contents),
      let servers = root["mcpServers"] as? [String: Any],
      let entry = servers[spec.name] as? [String: Any]
    else { return .notConfigured }

    let command = entry["command"] as? String
    let args = entry["args"] as? [String]
    let commandMatches = command.map(spec.matches(command:)) ?? false
    return (commandMatches && args == spec.args) ? .configured : .configuredDifferently
  }

  private static func serverEntry(for spec: AgentMCPServerSpec) -> [String: Any] {
    ["command": spec.command, "args": spec.args]
  }

  private static func parseObject(_ contents: String) throws -> [String: Any] {
    let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return [:] }
    guard let data = trimmed.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data),
      let dictionary = object as? [String: Any]
    else {
      throw ConfigError.invalidJSON
    }
    return dictionary
  }
}

/// The real, on-disk `~/.cursor/mcp.json` (or a temp-dir stand-in, in tests) that
/// ``CursorMCPConfigEditor`` reads and writes.
///
/// `@unchecked Sendable` — see ``CLIInstaller``'s documentation for why storing a `FileManager`
/// makes that necessary.
public struct CursorMCPConfigFile: @unchecked Sendable {
  public let path: String
  private let fileManager: FileManager

  /// - Parameters:
  ///   - path: Full path to `mcp.json`. Defaults to the real `~/.cursor/mcp.json`; tests should
  ///     always override this to a path under a fresh temp directory — never the real user's
  ///     Cursor config.
  public init(path: String = NSHomeDirectory() + "/.cursor/mcp.json", fileManager: FileManager = .default) {
    self.path = path
    self.fileManager = fileManager
  }

  private func read() -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
  }

  public func status(for spec: AgentMCPServerSpec = .lilpass) -> AgentMCPConnectionStatus {
    CursorMCPConfigEditor.status(of: spec, in: read())
  }

  public func snippet(for spec: AgentMCPServerSpec = .lilpass) -> String {
    CursorMCPConfigEditor.snippetEntry(for: spec)
  }

  /// Idempotently upserts `spec`'s entry into the file, creating `~/.cursor/` if needed and
  /// backing up any existing file first (`mcp.json.bak`, overwritten each time).
  public func addAutomatically(spec: AgentMCPServerSpec = .lilpass) throws {
    let directory = (path as NSString).deletingLastPathComponent
    try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)

    let existing = fileManager.fileExists(atPath: path) ? read() : nil
    if let existing {
      try existing.write(toFile: path + ".bak", atomically: true, encoding: .utf8)
    }
    let updated = try CursorMCPConfigEditor.upsert(spec: spec, in: existing ?? "")
    try updated.write(toFile: path, atomically: true, encoding: .utf8)
  }
}
