import Foundation
import LilPasswordsKit
import LilpassCore
import MCP
import Testing

#if canImport(System)
  import System
#else
  @preconcurrency import SystemPackage
#endif

/// Drives a real `lilpass mcp` subprocess over real stdio pipes with the MCP Swift SDK's own
/// `Client`/`StdioTransport` — the actual wire path an MCP-capable agent (Claude Code, Codex,
/// Cursor) uses, per 851-2434 ("an MCP stdio session (initialize, tools/list, tools/call)"). This
/// is the stdio-transport analog of `LilpassMCPServerTests` in `LilpassMCPTests`, which exercises the
/// same tool logic in-process over `InMemoryTransport` — here nothing is in-process: `lilpass mcp` is
/// a genuine child process, backed by a disposable `LilpassE2EHelper` over real XPC.
///
/// `.timeLimit(.minutes(1))`: every test here talks to a real subprocess over real XPC, and
/// this suite has twice hung a CI job for its full 30-minute timeout with zero output when one
/// of those calls never returned — a per-test time limit turns that into a fast, attributable
/// failure (naming exactly which test timed out) instead of another silent freeze.
///
/// `.serialized`: root cause of the CI-only hang, found by `sample`-ing the stuck process on CI
/// (see .github/workflows/ci.yml's E2E step) — the hang wasn't in our helper/XPC/MCP code at all,
/// it was the Swift runtime itself, spinning inside `swift::MetadataCacheEntryBase::
/// awaitSatisfyingState` while instantiating generic metadata reachable from `Client.connect
/// (transport:)`'s `AsyncThrowingStream` plumbing (in the MCP Swift SDK). That function is a
/// classic lock-free-cache "wait for the other thread to finish instantiating this same generic
/// type" spin, and this suite is the only one in the package that calls it — every test here
/// starts its own `Client` and calls `connect(transport:)`, and without `.serialized` swift-testing
/// runs them all in parallel, so on first run every one of those tasks would race to instantiate
/// the exact same generic metadata simultaneously. That race apparently never loses on a beefier
/// dev Mac, but reliably livelocks on CI's more core-constrained runner. Serializing this suite
/// means only one test ever does that first-time instantiation at once, removing the race outright
/// — it's a suite-local, always-safe fix regardless of whether it's also a genuine Swift runtime
/// bug worth reporting upstream.
@Suite(.timeLimit(.minutes(1)), .serialized)
struct MCPStdioSessionTests {
  /// Starts a `LilpassE2EHelper` plus a `lilpass mcp` child process wired to it, connects an MCP
  /// `Client` over their shared stdio pipes, and returns everything the caller needs to talk to it
  /// and clean it up.
  private func startSession(
    items: [PasswordItem] = [],
    locked: Bool = false
  ) async throws -> (helper: E2EHelperProcess, process: Process, client: Client) {
    let helper = try E2EHelperProcess.start(
      helperBinaryPath: LilpassBinary.helperPath,
      items: items,
      locked: locked
    )
    let (process, stdin, stdout) = try LilpassBinary.startMCPServer(extraEnvironment: [
      "LILPASS_E2E_MACH_SERVICE_NAME": helper.machServiceName
    ])

    let transport = StdioTransport(
      input: FileDescriptor(rawValue: stdout.fileHandleForReading.fileDescriptor),
      output: FileDescriptor(rawValue: stdin.fileHandleForWriting.fileDescriptor)
    )
    let client = Client(name: "lilpass-e2e-test-client", version: "1.0.0")
    _ = try await client.connect(transport: transport)

    return (helper, process, client)
  }

  /// `terminate()` only requests a graceful exit (`SIGTERM`) — if `lilpass mcp` somehow never acts
  /// on it, a bare `waitUntilExit()` right after would hang this teardown (and, per this suite's
  /// own `.timeLimit`, eventually the whole test) indefinitely. The watchdog below forces the issue
  /// with `SIGKILL` after a generous deadline so a stuck child can never outlive its test.
  private func stop(_ session: (helper: E2EHelperProcess, process: Process, client: Client)) {
    session.process.terminate()
    let deadline = DispatchTime.now() + .seconds(5)
    while session.process.isRunning, DispatchTime.now() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if session.process.isRunning {
      kill(session.process.processIdentifier, SIGKILL)
    }
    session.process.waitUntilExit()
    session.helper.stop()
  }

  @Test func initializesAndListsAllEightTools() async throws {
    let session = try await startSession()
    defer { stop(session) }

    let (tools, _) = try await session.client.listTools()
    #expect(
      Set(tools.map(\.name)) == [
        "list_passwords", "search_passwords", "get_password", "get_verification_code", "generate_password",
        "create_password", "update_password", "delete_password",
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
    // Same message `AgentError.locked.description` produces, per LilpassMCP's dispatch (`LilpassError.from`)
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
