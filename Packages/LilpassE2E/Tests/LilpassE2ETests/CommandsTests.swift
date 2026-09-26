import Foundation
import LilPasswordsKit
import LilpassCore
import Testing

/// Drives the *built* `lilpass` binary as a real subprocess against a real, disposable
/// `LilpassE2EHelper` over a real cross-process XPC connection (via `E2EHelperProcess`) — not the
/// in-process harness `LilpassCoreTests`/`LilpassMCPTests` use. Covers every command's plain-text
/// stdout, its `--json` output, and its exit code, per 851-2434.
///
/// `.timeLimit(.minutes(1))`: every test here talks to a real subprocess over real XPC, and
/// this suite has twice hung a CI job for its full 30-minute timeout with zero output when one
/// of those calls never returned — a per-test time limit turns that into a fast, attributable
/// failure (naming exactly which test timed out) instead of another silent freeze.
///
/// `.serialized`: see `MCPStdioSessionTests`'s doc comment for the full root cause (a Swift
/// runtime generic-metadata-cache livelock in `swift::MetadataCacheEntryBase::
/// awaitSatisfyingState`, triggered by multiple tests racing to instantiate the same generic type
/// for the first time in parallel). That suite was serialized as the fix the first time this was
/// diagnosed; a later CI run hung again with *zero* test output at all — worse, and consistent
/// with the same race now happening across this package's other, still-parallel suites instead
/// (they all share the same `Process`/`Pipe`/`readToEndCompat` generic machinery in
/// `LilpassBinary`/`E2EHelperProcess`). Serializing every suite in this package removes that cross-
/// suite race outright, at the cost of this suite's tests no longer running concurrently with each
/// other or with the rest of the package.
@Suite(.timeLimit(.minutes(1)), .serialized)
struct CommandsTests {
  init() {
    HangWatchdog.arm()
    HangWatchdog.trace("CommandsTests.init()")
  }

  @Test func statusReportsUnlockedAndEnabled() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath)
    defer { helper.stop() }

    let text = try LilpassBinary.run(["status"], extraEnvironment: env(for: helper))
    #expect(text.exitCode == LilpassExitCode.ok.rawValue)
    #expect(text.stdout.contains("locked: false"))
    #expect(text.stdout.contains("agentAccessEnabled: true"))

    let json = try LilpassBinary.run(["status", "--json"], extraEnvironment: env(for: helper))
    #expect(json.exitCode == LilpassExitCode.ok.rawValue)
    let status = try decode(AgentStatus.self, from: json.stdout)
    #expect(status.locked == false)
    #expect(status.agentAccessEnabled == true)
  }

  @Test func listPrintsEveryItemWithoutSecrets() throws {
    let item = makeE2ETestItem(title: "GitHub", usernames: ["octocat"], password: "hunter2", group: "Work")
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath, items: [item])
    defer { helper.stop() }

    let text = try LilpassBinary.run(["list"], extraEnvironment: env(for: helper))
    #expect(text.exitCode == LilpassExitCode.ok.rawValue)
    #expect(text.stdout.contains("GitHub"))
    #expect(text.stdout.contains("[Work]"))
    #expect(!text.stdout.contains("hunter2"))

    let json = try LilpassBinary.run(["list", "--json"], extraEnvironment: env(for: helper))
    let summaries = try decode([ItemSummary].self, from: json.stdout)
    #expect(summaries.map(\.id) == [item.id])

    let filtered = try LilpassBinary.run(["list", "--category", "work"], extraEnvironment: env(for: helper))
    #expect(filtered.stdout.contains("GitHub"))
  }

  @Test func listWithNoItemsPrintsNoItems() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath)
    defer { helper.stop() }

    let text = try LilpassBinary.run(["list"], extraEnvironment: env(for: helper))
    #expect(text.exitCode == LilpassExitCode.ok.rawValue)
    #expect(text.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "no items")
  }

  @Test func searchMatchesByUsername() throws {
    let item = makeE2ETestItem(title: "GitHub", usernames: ["octocat"])
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath, items: [item])
    defer { helper.stop() }

    let result = try LilpassBinary.run(["search", "octocat"], extraEnvironment: env(for: helper))
    #expect(result.exitCode == LilpassExitCode.ok.rawValue)
    #expect(result.stdout.contains("GitHub"))

    let json = try LilpassBinary.run(["search", "octocat", "--json"], extraEnvironment: env(for: helper))
    let summaries = try decode([ItemSummary].self, from: json.stdout)
    #expect(summaries.map(\.id) == [item.id])
  }

  @Test func getWithoutFieldPrintsTheFullSecretRevealingDetail() throws {
    let item = makeE2ETestItem(title: "GitHub", usernames: ["octocat"], password: "hunter2", notes: "backup: 1234")
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath, items: [item])
    defer { helper.stop() }

    let text = try LilpassBinary.run(["get", "GitHub"], extraEnvironment: env(for: helper))
    #expect(text.exitCode == LilpassExitCode.ok.rawValue)
    #expect(text.stdout.contains("password: hunter2"))
    #expect(text.stdout.contains("notes: backup: 1234"))

    let json = try LilpassBinary.run(["get", "GitHub", "--json"], extraEnvironment: env(for: helper))
    let detail = try decode(ItemDetail.self, from: json.stdout)
    #expect(detail.password == "hunter2")
  }

  @Test func getWithFieldPrintsJustThatValue() throws {
    let item = makeE2ETestItem(title: "GitHub", usernames: ["octocat"], password: "hunter2")
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath, items: [item])
    defer { helper.stop() }

    let text = try LilpassBinary.run(["get", "GitHub", "--field", "password"], extraEnvironment: env(for: helper))
    #expect(text.exitCode == LilpassExitCode.ok.rawValue)
    #expect(text.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hunter2")

    let json = try LilpassBinary.run(
      ["get", "GitHub", "--field", "username", "--json"],
      extraEnvironment: env(for: helper)
    )
    let value = try decode(FieldValue.self, from: json.stdout)
    #expect(value.value == "octocat")
  }

  @Test func readResolvesALilpassReference() throws {
    let item = makeE2ETestItem(title: "GitHub", password: "hunter2")
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath, items: [item])
    defer { helper.stop() }

    let result = try LilpassBinary.run(["read", "lilpass://GitHub/password"], extraEnvironment: env(for: helper))
    #expect(result.exitCode == LilpassExitCode.ok.rawValue)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hunter2")
  }

  @Test func readRejectsAMalformedReference() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath)
    defer { helper.stop() }

    let result = try LilpassBinary.run(["read", "not-a-reference"], extraEnvironment: env(for: helper))
    #expect(result.exitCode == LilpassExitCode.usage.rawValue)
  }

  @Test func totpPrintsASixDigitCode() throws {
    let item = makeE2ETestItem(
      title: "GitHub",
      totpURI: "otpauth://totp/GitHub:octocat?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"
    )
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath, items: [item])
    defer { helper.stop() }

    let result = try LilpassBinary.run(["totp", "GitHub"], extraEnvironment: env(for: helper))
    #expect(result.exitCode == LilpassExitCode.ok.rawValue)
    let code = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(code.count == 6)
    #expect(code.allSatisfy { $0.isNumber })
  }

  @Test func generateWithNoLengthProducesAppleStrongFormat() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath)
    defer { helper.stop() }

    let result = try LilpassBinary.run(["generate"], extraEnvironment: env(for: helper))
    #expect(result.exitCode == LilpassExitCode.ok.rawValue)
    #expect(result.stdout.contains("-"))
  }

  @Test func generateWithLengthProducesACustomPassword() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath)
    defer { helper.stop() }

    let result = try LilpassBinary.run(
      ["generate", "--length", "16", "--no-symbols"],
      extraEnvironment: env(for: helper)
    )
    #expect(result.exitCode == LilpassExitCode.ok.rawValue)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).count == 16)
  }

  // MARK: - Helpers

  private func env(for helper: E2EHelperProcess) -> [String: String] {
    ["LILPASS_E2E_MACH_SERVICE_NAME": helper.machServiceName]
  }

  private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
    try LilpassJSONTestDecoding.decoder.decode(type, from: Data(json.utf8))
  }
}

/// Mirrors `LilpassJSON`'s encoder configuration (sorted keys, ISO-8601 dates) on the decoding side
/// — `JSONDecoder`'s `.iso8601` date strategy is what actually matters for round-tripping
/// `AgentStatus`/`ItemSummary`/etc back out of `--json` output; key order doesn't affect decoding.
private enum LilpassJSONTestDecoding {
  static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
