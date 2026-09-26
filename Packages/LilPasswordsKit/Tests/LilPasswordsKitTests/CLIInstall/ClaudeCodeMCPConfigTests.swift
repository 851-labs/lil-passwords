import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct ClaudeCodeMCPConfigTests {
  /// A fake `ClaudeCodeCLIRunning` whose behavior is scripted up front, so tests never shell out
  /// to a real `claude` binary (which may not even be installed on the machine running the suite).
  private final class FakeCLI: ClaudeCodeCLIRunning, @unchecked Sendable {
    var locatedPath: String?
    /// Maps an argument list to the output `run` should return for it.
    var responses: [[String]: String] = [:]
    private(set) var runCalls: [[String]] = []

    func locate() -> String? { locatedPath }

    func run(_ arguments: [String]) throws -> String {
      runCalls.append(arguments)
      guard locatedPath != nil else {
        throw ClaudeCodeMCPConfigurator.ConfigurationError.claudeNotFound
      }
      return responses[arguments] ?? ""
    }
  }

  @Test func copySnippetMatchesTheDocumentedCommand() {
    #expect(ClaudeCodeMCPConfigurator.copySnippet() == "claude mcp add lilpass -- lilpass mcp")
  }

  @Test func isAvailableReflectsWhetherClaudeIsOnPath() {
    let cli = FakeCLI()
    #expect(ClaudeCodeMCPConfigurator(cli: cli).isAvailable == false)

    cli.locatedPath = "/usr/local/bin/claude"
    #expect(ClaudeCodeMCPConfigurator(cli: cli).isAvailable == true)
  }

  @Test func statusIsNotConfiguredWhenClaudeIsntAvailable() {
    let cli = FakeCLI()
    let configurator = ClaudeCodeMCPConfigurator(cli: cli)
    #expect(configurator.status() == .notConfigured)
    #expect(cli.runCalls.isEmpty)
  }

  @Test func statusIsConfiguredWhenListingMentionsLilpass() {
    let cli = FakeCLI()
    cli.locatedPath = "/usr/local/bin/claude"
    cli.responses[["mcp", "list"]] = "some-other-tool: node server.js\nlilpass: lilpass mcp\n"
    #expect(ClaudeCodeMCPConfigurator(cli: cli).status() == .configured)
  }

  @Test func statusIsNotConfiguredWhenListingOmitsLilpass() {
    let cli = FakeCLI()
    cli.locatedPath = "/usr/local/bin/claude"
    cli.responses[["mcp", "list"]] = "some-other-tool: node server.js\n"
    #expect(ClaudeCodeMCPConfigurator(cli: cli).status() == .notConfigured)
  }

  @Test func addAutomaticallyThrowsWhenClaudeIsntAvailable() {
    let cli = FakeCLI()
    let configurator = ClaudeCodeMCPConfigurator(cli: cli)
    #expect(throws: ClaudeCodeMCPConfigurator.ConfigurationError.claudeNotFound) {
      try configurator.addAutomatically()
    }
  }

  @Test func addAutomaticallyRunsMcpAddWithUserScope() throws {
    let cli = FakeCLI()
    cli.locatedPath = "/usr/local/bin/claude"
    let configurator = ClaudeCodeMCPConfigurator(cli: cli)
    try configurator.addAutomatically()
    #expect(cli.runCalls == [["mcp", "add", "--scope", "user", "lilpass", "--", "lilpass", "mcp"]])
  }
}
