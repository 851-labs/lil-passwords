import Foundation
import LilPasswordsKit
import LilpwCore
import MCP
import Testing

#if canImport(System)
  import System
#else
  @preconcurrency import SystemPackage
#endif

/// Drives a real `lilpw mcp` subprocess over real stdio pipes with the MCP Swift SDK's own
/// `Client`/`StdioTransport` — the actual wire path an MCP-capable agent (Claude Code, Codex,
/// Cursor) uses, per 851-2434 ("an MCP stdio session (initialize, tools/list, tools/call)"). This
/// is the stdio-transport analog of `LilpwMCPServerTests` in `LilpwMCPTests`, which exercises the
/// same tool logic in-process over `InMemoryTransport` — here nothing is in-process: `lilpw mcp` is
/// a genuine child process, backed by a disposable `LilpwE2EHelper` over real XPC.
@Suite struct MCPStdioSessionTests {
  /// Starts a `LilpwE2EHelper` plus a `lilpw mcp` child process wired to it, connects an MCP
  /// `Client` over their shared stdio pipes, and returns everything the caller needs to talk to it
  /// and clean it up.
  private func startSession(
    items: [PasswordItem] = [],
    locked: Bool = false
  ) async throws -> (helper: E2EHelperProcess, process: Process, client: Client) {
    let helper = try E2EHelperProcess.start(
      helperBinaryPath: LilpwBinary.helperPath,
      items: items,
      locked: locked
    )
    let (process, stdin, stdout) = try LilpwBinary.startMCPServer(extraEnvironment: [
      "LILPW_E2E_MACH_SERVICE_NAME": helper.machServiceName
    ])

    let transport = StdioTransport(
      input: FileDescriptor(rawValue: stdout.fileHandleForReading.fileDescriptor),
      output: FileDescriptor(rawValue: stdin.fileHandleForWriting.fileDescriptor)
    )
    let client = Client(name: "lilpw-e2e-test-client", version: "1.0.0")
    _ = try await client.connect(transport: transport)

    return (helper, process, client)
  }

  private func stop(_ session: (helper: E2EHelperProcess, process: Process, client: Client)) {
    session.process.terminate()
    session.process.waitUntilExit()
    session.helper.stop()
  }

  @Test func initializesAndListsAllFiveTools() async throws {
    let session = try await startSession()
    defer { stop(session) }

    let (tools, _) = try await session.client.listTools()
    #expect(
      Set(tools.map(\.name)) == [
        "list_passwords", "search_passwords", "get_password", "get_verification_code", "generate_password",
      ])
  }

  @Test func listPasswordsToolCallReturnsSummariesWithoutSecrets() async throws {
    let item = makeE2ETestItem(title: "GitHub", notes: "very secret notes")
    let session = try await startSession(items: [item])
    defer { stop(session) }

    let (content, isError) = try await session.client.callTool(name: "list_passwords")
    #expect(isError == false)
    let json = try #require(text(of: content))
    #expect(json.contains("GitHub"))
    #expect(!json.contains("very secret notes"))
  }

  @Test func getPasswordToolCallReturnsTheFullRecord() async throws {
    let item = makeE2ETestItem(title: "GitHub", password: "hunter2")
    let session = try await startSession(items: [item])
    defer { stop(session) }

    let (content, isError) = try await session.client.callTool(
      name: "get_password", arguments: ["item": "GitHub"])
    #expect(isError == false)
    let json = try #require(text(of: content))
    #expect(json.contains("hunter2"))
  }

  @Test func generatePasswordToolCallWithALength() async throws {
    let session = try await startSession()
    defer { stop(session) }

    let (content, isError) = try await session.client.callTool(
      name: "generate_password", arguments: ["length": 16, "noSymbols": true])
    #expect(isError == false)
    let json = try #require(text(of: content))
    #expect(json.contains("\"password\""))
  }

  @Test func aLockedVaultReturnsTheSameMessageTheCLIWouldPrint() async throws {
    let session = try await startSession(items: [makeE2ETestItem()], locked: true)
    defer { stop(session) }

    let (content, isError) = try await session.client.callTool(name: "list_passwords")
    #expect(isError == true)
    let message = try #require(text(of: content))
    // Same message `AgentError.locked.description` produces, per LilpwMCP's dispatch (`LilpwError.from`)
    // — the same text the CLI itself would print to stderr for a locked vault.
    #expect(message == "lil passwords is locked — unlock the app")
  }

  private func text(of content: [Tool.Content]) -> String? {
    for item in content {
      if case .text(let text, _, _) = item {
        return text
      }
    }
    return nil
  }
}
