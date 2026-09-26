import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct CursorMCPConfigEditorTests {
  @Test func statusIsNotConfiguredForEmptyContent() {
    #expect(CursorMCPConfigEditor.status(of: .lilpass, in: "") == .notConfigured)
  }

  @Test func upsertCreatesTheFileFromScratch() throws {
    let updated = try CursorMCPConfigEditor.upsert(spec: .lilpass, in: "")
    #expect(CursorMCPConfigEditor.status(of: .lilpass, in: updated) == .configured)
  }

  @Test func upsertPreservesOtherTopLevelKeysAndOtherServers() throws {
    let existing = """
      {
        "someOtherSetting": true,
        "mcpServers": {
          "other-tool": { "command": "other-tool", "args": [] }
        }
      }
      """
    let updated = try CursorMCPConfigEditor.upsert(spec: .lilpass, in: existing)
    #expect(CursorMCPConfigEditor.status(of: .lilpass, in: updated) == .configured)

    let data = try #require(updated.data(using: .utf8))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["someOtherSetting"] as? Bool == true)
    let servers = try #require(object["mcpServers"] as? [String: Any])
    #expect(servers["other-tool"] != nil)
    #expect(servers["lilpass"] != nil)
  }

  @Test func upsertReplacesAnExistingDifferentEntry() throws {
    let existing = """
      { "mcpServers": { "lilpass": { "command": "/old/lilpass", "args": ["serve"] } } }
      """
    let updated = try CursorMCPConfigEditor.upsert(spec: .lilpass, in: existing)
    #expect(CursorMCPConfigEditor.status(of: .lilpass, in: updated) == .configured)
    #expect(!updated.contains("/old/lilpass"))
  }

  @Test func upsertIsIdempotent() throws {
    let once = try CursorMCPConfigEditor.upsert(spec: .lilpass, in: "")
    let twice = try CursorMCPConfigEditor.upsert(spec: .lilpass, in: once)
    #expect(once == twice)
  }

  @Test func statusReportsConfiguredDifferentlyWhenArgsDontMatch() {
    let existing = """
      { "mcpServers": { "lilpass": { "command": "lilpass", "args": ["serve"] } } }
      """
    #expect(CursorMCPConfigEditor.status(of: .lilpass, in: existing) == .configuredDifferently)
  }

  @Test func upsertThrowsOnInvalidExistingJSON() {
    #expect(throws: CursorMCPConfigEditor.ConfigError.self) {
      try CursorMCPConfigEditor.upsert(spec: .lilpass, in: "{ not valid json")
    }
  }
}

@Suite struct CursorMCPConfigFileTests {
  /// A fresh temp directory standing in for `~/.cursor/` — never the real one.
  private func makeFile() -> (file: CursorMCPConfigFile, path: String) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let path = directory.appendingPathComponent("mcp.json").path
    return (CursorMCPConfigFile(path: path), path)
  }

  @Test func addAutomaticallyCreatesTheDirectoryAndFile() throws {
    let (file, path) = makeFile()
    try file.addAutomatically()
    #expect(FileManager.default.fileExists(atPath: path))
    #expect(file.status() == .configured)
  }

  @Test func addAutomaticallyBacksUpAnExistingFileBeforeOverwriting() throws {
    let (file, path) = makeFile()
    let directory = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let original = #"{ "mcpServers": { "other-tool": { "command": "other-tool", "args": [] } } }"#
    try original.write(toFile: path, atomically: true, encoding: .utf8)

    try file.addAutomatically()

    let backup = try String(contentsOfFile: path + ".bak", encoding: .utf8)
    #expect(backup == original)
    #expect(file.status() == .configured)
  }

  @Test func addAutomaticallyIsIdempotent() throws {
    let (file, _) = makeFile()
    try file.addAutomatically()
    try file.addAutomatically()
    #expect(file.status() == .configured)
  }

  @Test func statusIsNotConfiguredBeforeInstalling() {
    let (file, _) = makeFile()
    #expect(file.status() == .notConfigured)
  }
}
