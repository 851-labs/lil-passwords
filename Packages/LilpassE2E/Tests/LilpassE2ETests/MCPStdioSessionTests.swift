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
/// This suite hung CI's E2E job repeatedly, and its diagnosis went through three wrong-or-partial
/// turns before landing on the real causes (plural — there were two, stacked) — worth recording so
/// nobody re-treads the same dead ends:
///
/// 1. First theory: parallel tests within this suite raced to instantiate the same generic
///    metadata the first time `Client.connect(transport:)` ran, livelocking in the Swift runtime's
///    `swift::MetadataCacheEntryBase::awaitSatisfyingState`. Adding `.serialized` here "fixed" it —
///    for a while.
/// 2. It recurred anyway, now with all 5 of this package's suites' `init()`s interleaving. Second
///    theory: `.serialized` only serializes *within* a suite, and swift-testing still runs separate
///    suites concurrently by default, so the race was actually cross-suite. Adding `--no-parallel`
///    to the package's `swift test` invocation (see the Makefile's `e2e` target) "fixed" that — but
///    a CI run with `--no-parallel` in place still livelocked, 3 times in a row, always partway
///    through this suite specifically, with every suite's `init()` running strictly one at a time.
/// 3. Third theory, and the first real root cause (see `stop(_:)`'s `disconnect()` call below):
///    `Client.connect(transport:)` starts a background `Task` that runs a message-handling loop for
///    the client's *entire lifetime*, and this suite's teardown never disconnected the client — only
///    killed the child process and moved on. That Task doesn't reliably exit just because its process
///    died; it keeps running (and racing to instantiate the same generic metadata
///    `.serialized`/`--no-parallel` were meant to protect) until the killed process's stdout pipe
///    hits EOF, which isn't instant. Every test here built a fresh `Client`, so every test leaked one
///    more of these loops — by the 3rd or 4th test, several were alive simultaneously. Calling
///    `await session.client.disconnect()` in teardown fixed *this* — six full local repro runs after
///    landing it never once recurred in the generic-metadata-cache codepath — but three of those six
///    runs *still* hung, always in a different place: `-[NSConcreteTask waitUntilExit]`.
/// 4. The second, independent root cause (see `stop(_:)`'s final poll loop below): that leftover
///    `waitUntilExit()` call is a synchronous, blocking Objective-C API, called directly from this
///    `async` teardown. That blocks whichever of Swift Concurrency's cooperative-pool threads happens
///    to run it for as long as the wait takes — and that pool is sized to the machine's core count.
///    CI's runner has few cores; this package runs 31 tests, several of which (this suite's) each wait
///    on a whole subprocess's exit in teardown. Enough of those overlapping can exhaust the pool and
///    deadlock everything else that needs a pool thread next — including, apparently, whatever
///    bookkeeping that very `waitUntilExit()` call was itself waiting on, which is exactly why it never
///    resolved on its own. Replacing it with a plain `isRunning` poll via `Task.sleep` (a suspension
///    point, not a thread-blocking one) is the fix; the SIGKILL sent just above it guarantees the poll
///    stays short.
///
/// Both of those were verified with dozens of full local `swift test --no-parallel` runs — and then
/// the commit landing them failed *CI* immediately, in under a minute, on a plain compile error:
/// `'async' call cannot occur in a defer body`, from every one of this suite's original `defer {
/// await stop(session) }` cleanup lines. This local toolchain (Swift 6.4) accepts that construct with
/// only a stylistic warning; CI's toolchain at the time (Swift 6.2.4, via `xcodebuild -version` in the
/// "Tool versions" step) rejects it outright. Neither toolchain is "wrong" — this is simply a real
/// difference between them, and it's exactly the kind of gap an implicitly-different local Xcode can
/// hide indefinitely. `withSession(_:_:)` below replaces `defer` entirely with an explicit
/// `do`/`catch` so cleanup no longer depends on whether a given Swift version allows `await` inside a
/// `defer` body at all.
///
/// `.serialized` and the package's `--no-parallel` flag stay on regardless — they're cheap, and
/// still legitimate insurance against the *originally hypothesized* race actually existing somewhere
/// too — but don't assume either one is why this suite passes; `withSession`'s cleanup ordering and
/// the two fixes in `stop(_:)` are.
@Suite(.timeLimit(.minutes(1)), .serialized)
struct MCPStdioSessionTests {
  init() {
    HangWatchdog.arm()
    HangWatchdog.trace("MCPStdioSessionTests.init()")
  }

  /// Starts a `LilpassE2EHelper` plus a `lilpass mcp` child process wired to it, connects an MCP
  /// `Client` over their shared stdio pipes, and returns everything the caller needs to talk to it
  /// and clean it up.
  private func startSession(
    items: [PasswordItem] = [],
    locked: Bool = false
  ) async throws -> (helper: E2EHelperProcess, process: Process, client: Client) {
    HangWatchdog.trace("startSession(): starting E2EHelperProcess")
    let helper = try E2EHelperProcess.start(
      helperBinaryPath: LilpassBinary.helperPath,
      items: items,
      locked: locked
    )
    HangWatchdog.trace("startSession(): helper started, starting lilpass mcp subprocess")
    let (process, stdin, stdout) = try LilpassBinary.startMCPServer(extraEnvironment: [
      "LILPASS_E2E_MACH_SERVICE_NAME": helper.machServiceName
    ])

    let transport = StdioTransport(
      input: FileDescriptor(rawValue: stdout.fileHandleForReading.fileDescriptor),
      output: FileDescriptor(rawValue: stdin.fileHandleForWriting.fileDescriptor)
    )
    let client = Client(name: "lilpass-e2e-test-client", version: "1.0.0")
    HangWatchdog.trace("startSession(): calling client.connect(transport:)")
    _ = try await client.connect(transport: transport)
    HangWatchdog.trace("startSession(): client.connect(transport:) returned")

    return (helper, process, client)
  }

  /// Starts a session, hands its `Client` to `body`, and guarantees `stop(_:)` runs afterward
  /// whichever way `body` finishes — including when it throws (every test's `#expect`/`#require`
  /// failures raise, and a locked-vault tool call is expected to report an error but must not
  /// itself throw out of `body` uncleaned-up).
  ///
  /// This exists instead of each test writing `let session = try await startSession(); defer {
  /// await stop(session) }` directly, which is how this suite originally looked and which compiles
  /// fine on some Swift toolchains (confirmed locally: Swift 6.4 accepts an `await` inside a `defer`
  /// body with only a stylistic warning) but is rejected outright on others — CI's Swift 6.2.4 gives
  /// a hard `'async' call cannot occur in a defer body` error, which only surfaces once something
  /// forces a real CI compile of this exact code (as opposed to trusting a local toolchain that
  /// happens to be newer and more permissive). Threading cleanup through an explicit `do`/`catch`
  /// here instead sidesteps the question of which toolchains allow `defer { await ... }` entirely,
  /// rather than depending on it.
  private func withSession(
    items: [PasswordItem] = [],
    locked: Bool = false,
    _ body: (Client) async throws -> Void
  ) async throws {
    let session = try await startSession(items: items, locked: locked)
    do {
      try await body(session.client)
    } catch {
      await stop(session)
      throw error
    }
    await stop(session)
  }

  /// `terminate()` only requests a graceful exit (`SIGTERM`) — if `lilpass mcp` somehow never acts
  /// on it, a bare wait right after would hang this teardown (and, per this suite's own `.timeLimit`,
  /// eventually the whole test) indefinitely. The polling loop below forces the issue with `SIGKILL`
  /// after a generous deadline so a stuck child can never outlive its test.
  ///
  /// This function carries 851-2434's actual two-part fix — see the suite's doc comment above for
  /// the full diagnostic history of how each part was found:
  ///
  /// 1. `await session.client.disconnect()` must come first, and must actually be awaited.
  ///    `Client.connect(transport:)` starts a background `Task` that runs its message-handling loop
  ///    for the client's *entire lifetime*; `disconnect()` is the only way to cancel it. Without
  ///    calling it, that loop keeps running after a test returns — it only notices the connection is
  ///    gone once the killed `lilpass mcp` process's stdout pipe actually hits EOF, which isn't
  ///    instant — and because every test here builds a fresh `Client`, each test used to leak one more
  ///    of these loops, eventually racing each other (and a brand new test's own `connect(transport:)`
  ///    call) to instantiate the same generic metadata for the first time in the process.
  /// 2. The final wait for the child process's exit polls `isRunning` with `Task.sleep` rather than
  ///    calling `waitUntilExit()` — a synchronous, blocking call — directly from this `async` function.
  ///    Doing that ties up one of Swift Concurrency's cooperative-pool threads (sized to the machine's
  ///    core count) for the whole wait; enough of those overlapping on a low-core CI runner can exhaust
  ///    the pool and deadlock everything else needing a pool thread next.
  ///
  /// `.serialized` and the package's `--no-parallel` flag stay on as cheap, harmless insurance, but
  /// neither one touches either of the above — only this function's two fixes do.
  private func stop(_ session: (helper: E2EHelperProcess, process: Process, client: Client)) async {
    await session.client.disconnect()

    session.process.terminate()
    let deadline = DispatchTime.now() + .seconds(5)
    while session.process.isRunning, DispatchTime.now() < deadline {
      try? await Task.sleep(for: .milliseconds(50))
    }
    if session.process.isRunning {
      kill(session.process.processIdentifier, SIGKILL)
    }
    // Not `session.process.waitUntilExit()`: that's a synchronous, blocking Objective-C call, and
    // calling it directly from `async` code is its own footgun, distinct from (and layered underneath)
    // the leaked-Task one above. It ties up whichever of Swift Concurrency's cooperative-pool threads
    // happens to run this line for as long as the wait takes; that pool is sized to the machine's core
    // count, and CI's runner has few cores. A couple of tests' `waitUntilExit()` calls overlapping —
    // easy with 31 tests and 90s of headroom — can exhaust the whole pool and deadlock everything that
    // needs a pool thread to make progress next, including, it turns out, whatever bookkeeping this
    // very wait was depending on: confirmed by repeated local reproduction after the `disconnect()` fix
    // above landed, where every remaining hang's `sample` dump was stuck in exactly this call
    // (`-[NSConcreteTask waitUntilExit]`), never recurring in the generic-metadata-cache codepath that
    // `disconnect()` was fixing. Polling `isRunning` with `Task.sleep` — a suspension point, not a
    // thread-blocking one — gets the same answer without starving the pool. The SIGKILL above makes
    // this poll short-lived: the process cannot decline to die.
    while session.process.isRunning {
      try? await Task.sleep(for: .milliseconds(20))
    }
    session.helper.stop()
  }

  @Test func initializesAndListsAllEightTools() async throws {
    try await withSession { client in
      let (tools, _) = try await client.listTools()
      #expect(
        Set(tools.map(\.name)) == [
          "list_passwords", "search_passwords", "get_password", "get_verification_code", "generate_password",
          "create_password", "update_password", "delete_password",
        ])
    }
  }

  @Test func listPasswordsToolCallReturnsSummariesWithoutSecrets() async throws {
    let item = makeE2ETestItem(title: "GitHub", notes: "very secret notes")
    try await withSession(items: [item]) { client in
      let (content, isError) = try await client.callTool(name: "list_passwords")
      #expect(isError == false)
      let json = try #require(text(of: content))
      #expect(json.contains("GitHub"))
      #expect(!json.contains("very secret notes"))
    }
  }

  @Test func getPasswordToolCallReturnsTheFullRecord() async throws {
    let item = makeE2ETestItem(title: "GitHub", password: "hunter2")
    try await withSession(items: [item]) { client in
      let (content, isError) = try await client.callTool(
        name: "get_password", arguments: ["item": "GitHub"])
      #expect(isError == false)
      let json = try #require(text(of: content))
      #expect(json.contains("hunter2"))
    }
  }

  @Test func generatePasswordToolCallWithALength() async throws {
    try await withSession { client in
      let (content, isError) = try await client.callTool(
        name: "generate_password", arguments: ["length": 16, "noSymbols": true])
      #expect(isError == false)
      let json = try #require(text(of: content))
      #expect(json.contains("\"password\""))
    }
  }

  @Test func aLockedVaultReturnsTheSameMessageTheCLIWouldPrint() async throws {
    try await withSession(items: [makeE2ETestItem()], locked: true) { client in
      let (content, isError) = try await client.callTool(name: "list_passwords")
      #expect(isError == true)
      let message = try #require(text(of: content))
      // Same message `AgentError.locked.description` produces, per LilpassMCP's dispatch (`LilpassError.from`)
      // — the same text the CLI itself would print to stderr for a locked vault.
      #expect(message == "lil passwords is locked — unlock the app")
    }
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
