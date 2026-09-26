import Foundation

/// Pure text editing for Codex's `~/.codex/config.toml` `[mcp_servers.<name>]` block (851-2432).
///
/// Deliberately not a general TOML parser/serializer — there's no TOML dependency in this
/// package (see `Package.swift`'s comment on why `LilPasswordsKit` stays dependency-light), and a
/// full parser would be a lot of surface area for editing exactly one table with two known keys.
/// Instead this finds the `[mcp_servers.<name>]` header line (if any) and treats everything up to
/// the next top-level `[...]` header (or end of file) as "our" block, so re-running `upsert` is
/// idempotent and every other table in the file is left untouched, line for line.
///
/// All functions here are pure (`String` in, `String`/`AgentMCPConnectionStatus` out) so they're
/// unit-testable directly, without touching any file at all — `CodexMCPConfigFile` below is the
/// thin, real-file wrapper.
public enum CodexMCPConfigEditor {
  /// The exact block `upsert`/the "Copy Setup" button produce for `spec`.
  public static func block(for spec: AgentMCPServerSpec) -> String {
    """
    [mcp_servers.\(spec.name)]
    command = "\(spec.command)"
    args = [\(spec.args.map { "\"\($0)\"" }.joined(separator: ", "))]
    """
  }

  /// Returns `contents` with `spec`'s block inserted or replaced. Idempotent: calling this twice
  /// in a row with the same `spec` produces the same output as calling it once.
  public static func upsert(spec: AgentMCPServerSpec, in contents: String) -> String {
    let header = tableHeader(for: spec.name)
    // Split on a body with any single trailing newline removed first, so a file that already
    // ends with "\n" (as every output of this function does) doesn't leave a trailing empty
    // line in `lines` — otherwise `blockRange` would swallow that empty line as part of "our"
    // block when it's the last one in the file, and re-running `upsert` on its own prior output
    // would drop the trailing newline, breaking idempotency.
    let body = contents.hasSuffix("\n") ? String(contents.dropLast()) : contents
    let lines = body.isEmpty ? [] : body.components(separatedBy: "\n")

    guard let range = blockRange(forHeader: header, in: lines) else {
      // No existing block: append, with exactly one blank line separating it from whatever's
      // already there (and none at all if the file was empty).
      let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? block(for: spec) + "\n" : trimmed + "\n\n" + block(for: spec) + "\n"
    }

    var updatedLines = lines
    updatedLines.replaceSubrange(range, with: block(for: spec).components(separatedBy: "\n"))
    return updatedLines.joined(separator: "\n") + "\n"
  }

  /// Whether `contents` already has a `[mcp_servers.<spec.name>]` block matching `spec` exactly,
  /// a differing one, or none at all.
  public static func status(of spec: AgentMCPServerSpec, in contents: String) -> AgentMCPConnectionStatus {
    let header = tableHeader(for: spec.name)
    let lines = contents.components(separatedBy: "\n")
    guard let range = blockRange(forHeader: header, in: lines) else { return .notConfigured }

    let blockLines = lines[range]
    let command = blockLines.lazy.compactMap { parseStringValue(fromLineStartingWith: "command", in: $0) }.first
    let args = blockLines.lazy.compactMap { parseStringArrayValue(fromLineStartingWith: "args", in: $0) }.first

    return (command == spec.command && args == spec.args) ? .configured : .configuredDifferently
  }

  private static func tableHeader(for name: String) -> String {
    "[mcp_servers.\(name)]"
  }

  /// The line range `[header, ..., end)` covering the header and every line until (but not
  /// including) the next top-level `[...]` header, or the end of the array.
  private static func blockRange(forHeader header: String, in lines: [String]) -> Range<Int>? {
    guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else {
      return nil
    }
    var end = start + 1
    while end < lines.count {
      let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("[") { break }
      end += 1
    }
    return start..<end
  }

  private static func parseStringValue(fromLineStartingWith key: String, in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("\(key) ") || trimmed.hasPrefix("\(key)=") else { return nil }
    guard let equalsIndex = trimmed.firstIndex(of: "=") else { return nil }
    let value = trimmed[trimmed.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
    guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return nil }
    return String(value.dropFirst().dropLast())
  }

  private static func parseStringArrayValue(fromLineStartingWith key: String, in line: String) -> [String]? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("\(key) ") || trimmed.hasPrefix("\(key)=") else { return nil }
    guard let equalsIndex = trimmed.firstIndex(of: "=") else { return nil }
    var value = trimmed[trimmed.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
    guard value.hasPrefix("["), value.hasSuffix("]") else { return nil }
    value = value.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
    if value.isEmpty { return [] }
    return value.components(separatedBy: ",").map {
      $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
  }
}

/// The real, on-disk `~/.codex/config.toml` (or a temp-dir stand-in, in tests) that
/// ``CodexMCPConfigEditor`` reads and writes.
///
/// `@unchecked Sendable` — see ``CLIInstaller``'s documentation for why storing a `FileManager`
/// makes that necessary.
public struct CodexMCPConfigFile: @unchecked Sendable {
  public let path: String
  private let fileManager: FileManager

  /// - Parameters:
  ///   - path: Full path to `config.toml`. Defaults to the real `~/.codex/config.toml`; tests
  ///     should always override this to a path under a fresh temp directory — never the real
  ///     user's Codex config.
  public init(path: String = NSHomeDirectory() + "/.codex/config.toml", fileManager: FileManager = .default) {
    self.path = path
    self.fileManager = fileManager
  }

  private func read() -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
  }

  public func status(for spec: AgentMCPServerSpec = .lilpass) -> AgentMCPConnectionStatus {
    CodexMCPConfigEditor.status(of: spec, in: read())
  }

  /// The exact block a "Copy Setup" action should put on the pasteboard.
  public func snippet(for spec: AgentMCPServerSpec = .lilpass) -> String {
    CodexMCPConfigEditor.block(for: spec)
  }

  /// Idempotently upserts `spec`'s block into the file, creating `~/.codex/` if needed and
  /// backing up any existing file first (`config.toml.bak`, overwritten each time — this mirrors
  /// how e.g. `visudo`/package managers keep exactly one "previous version," not an
  /// ever-growing history).
  public func addAutomatically(spec: AgentMCPServerSpec = .lilpass) throws {
    let directory = (path as NSString).deletingLastPathComponent
    try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)

    let existing = fileManager.fileExists(atPath: path) ? read() : nil
    if let existing {
      try existing.write(toFile: path + ".bak", atomically: true, encoding: .utf8)
    }
    let updated = CodexMCPConfigEditor.upsert(spec: spec, in: existing ?? "")
    try updated.write(toFile: path, atomically: true, encoding: .utf8)
  }
}
