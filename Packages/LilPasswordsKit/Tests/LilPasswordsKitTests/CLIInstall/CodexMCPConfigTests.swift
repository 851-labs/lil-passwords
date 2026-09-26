import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct CodexMCPConfigEditorTests {
  @Test func statusIsNotConfiguredForEmptyContent() {
    #expect(CodexMCPConfigEditor.status(of: .lilpass, in: "") == .notConfigured)
  }

  @Test func upsertAppendsBlockToEmptyContent() {
    let updated = CodexMCPConfigEditor.upsert(spec: .lilpass, in: "")
    #expect(updated == CodexMCPConfigEditor.block(for: .lilpass) + "\n")
    #expect(CodexMCPConfigEditor.status(of: .lilpass, in: updated) == .configured)
  }

  @Test func upsertAppendsBlockAfterExistingUnrelatedContent() {
    let existing = """
      [some_other_table]
      key = "value"
      """
    let updated = CodexMCPConfigEditor.upsert(spec: .lilpass, in: existing)
    #expect(updated.contains("[some_other_table]"))
    #expect(updated.contains("key = \"value\""))
    #expect(CodexMCPConfigEditor.status(of: .lilpass, in: updated) == .configured)
  }

  @Test func upsertReplacesAnExistingBlockInPlaceRatherThanDuplicatingIt() {
    let existing = """
      [mcp_servers.lilpass]
      command = "/old/path/lilpass"
      args = ["mcp", "--legacy"]

      [some_other_table]
      key = "value"
      """
    let updated = CodexMCPConfigEditor.upsert(spec: .lilpass, in: existing)

    #expect(updated.components(separatedBy: "[mcp_servers.lilpass]").count == 2)
    #expect(updated.contains("[some_other_table]"))
    #expect(updated.contains("key = \"value\""))
    #expect(CodexMCPConfigEditor.status(of: .lilpass, in: updated) == .configured)
    #expect(!updated.contains("/old/path/lilpass"))
  }

  @Test func upsertIsIdempotent() {
    let once = CodexMCPConfigEditor.upsert(spec: .lilpass, in: "")
    let twice = CodexMCPConfigEditor.upsert(spec: .lilpass, in: once)
    #expect(once == twice)
  }

  @Test func statusReportsConfiguredDifferentlyWhenCommandDoesntMatch() {
    let existing = """
      [mcp_servers.lilpass]
      command = "/some/other/lilpass"
      args = ["mcp"]
      """
    #expect(CodexMCPConfigEditor.status(of: .lilpass, in: existing) == .configuredDifferently)
  }

  @Test func statusReportsConfiguredDifferentlyWhenArgsDontMatch() {
    let existing = """
      [mcp_servers.lilpass]
      command = "lilpass"
      args = ["serve"]
      """
    #expect(CodexMCPConfigEditor.status(of: .lilpass, in: existing) == .configuredDifferently)
  }

  @Test func leavesAnotherServersBlockUntouched() {
    let existing = """
      [mcp_servers.other]
      command = "other-tool"
      args = []
      """
    let updated = CodexMCPConfigEditor.upsert(spec: .lilpass, in: existing)
    #expect(updated.contains("[mcp_servers.other]"))
    #expect(CodexMCPConfigEditor.status(of: .lilpass, in: updated) == .configured)
  }
}

@Suite struct CodexMCPConfigFileTests {
  /// A fresh temp directory standing in for `~/.codex/` — never the real one.
  private func makeFile() -> (file: CodexMCPConfigFile, path: String) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let path = directory.appendingPathComponent("config.toml").path
    return (CodexMCPConfigFile(path: path), path)
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
    let original = "[some_other_table]\nkey = \"value\"\n"
    try original.write(toFile: path, atomically: true, encoding: .utf8)

    try file.addAutomatically()

    let backup = try String(contentsOfFile: path + ".bak", encoding: .utf8)
    #expect(backup == original)
    let updated = try String(contentsOfFile: path, encoding: .utf8)
    #expect(updated.contains("[some_other_table]"))
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
