import Foundation
import LilPasswordsKit
import LilpwCore
import Testing

/// Drives the *built* `lilpw` binary as a real subprocess against a real, disposable
/// `LilpwE2EHelper` over a real cross-process XPC connection (via `E2EHelperProcess`) — not the
/// in-process harness `LilpwCoreTests`/`LilpwMCPTests` use. Covers every command's plain-text
/// stdout, its `--json` output, and its exit code, per 851-2434.
@Suite struct CommandsTests {
  @Test func statusReportsUnlockedAndEnabled() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath)
    defer { helper.stop() }

    let text = try LilpwBinary.run(["status"], extraEnvironment: env(for: helper))
    #expect(text.exitCode == LilpwExitCode.ok.rawValue)
    #expect(text.stdout.contains("locked: false"))
    #expect(text.stdout.contains("agentAccessEnabled: true"))

    let json = try LilpwBinary.run(["status", "--json"], extraEnvironment: env(for: helper))
    #expect(json.exitCode == LilpwExitCode.ok.rawValue)
    let status = try decode(AgentStatus.self, from: json.stdout)
    #expect(status.locked == false)
    #expect(status.agentAccessEnabled == true)
  }

  @Test func listPrintsEveryItemWithoutSecrets() throws {
    let item = makeE2ETestItem(title: "GitHub", usernames: ["octocat"], password: "hunter2", group: "Work")
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath, items: [item])
    defer { helper.stop() }

    let text = try LilpwBinary.run(["list"], extraEnvironment: env(for: helper))
    #expect(text.exitCode == LilpwExitCode.ok.rawValue)
    #expect(text.stdout.contains("GitHub"))
    #expect(text.stdout.contains("[Work]"))
    #expect(!text.stdout.contains("hunter2"))

    let json = try LilpwBinary.run(["list", "--json"], extraEnvironment: env(for: helper))
    let summaries = try decode([ItemSummary].self, from: json.stdout)
    #expect(summaries.map(\.id) == [item.id])

    let filtered = try LilpwBinary.run(["list", "--category", "work"], extraEnvironment: env(for: helper))
    #expect(filtered.stdout.contains("GitHub"))
  }

  @Test func listWithNoItemsPrintsNoItems() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath)
    defer { helper.stop() }

    let text = try LilpwBinary.run(["list"], extraEnvironment: env(for: helper))
    #expect(text.exitCode == LilpwExitCode.ok.rawValue)
    #expect(text.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "no items")
  }

  @Test func searchMatchesByUsername() throws {
    let item = makeE2ETestItem(title: "GitHub", usernames: ["octocat"])
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath, items: [item])
    defer { helper.stop() }

    let result = try LilpwBinary.run(["search", "octocat"], extraEnvironment: env(for: helper))
    #expect(result.exitCode == LilpwExitCode.ok.rawValue)
    #expect(result.stdout.contains("GitHub"))

    let json = try LilpwBinary.run(["search", "octocat", "--json"], extraEnvironment: env(for: helper))
    let summaries = try decode([ItemSummary].self, from: json.stdout)
    #expect(summaries.map(\.id) == [item.id])
  }

  @Test func getWithoutFieldPrintsTheFullSecretRevealingDetail() throws {
    let item = makeE2ETestItem(title: "GitHub", usernames: ["octocat"], password: "hunter2", notes: "backup: 1234")
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath, items: [item])
    defer { helper.stop() }

    let text = try LilpwBinary.run(["get", "GitHub"], extraEnvironment: env(for: helper))
    #expect(text.exitCode == LilpwExitCode.ok.rawValue)
    #expect(text.stdout.contains("password: hunter2"))
    #expect(text.stdout.contains("notes: backup: 1234"))

    let json = try LilpwBinary.run(["get", "GitHub", "--json"], extraEnvironment: env(for: helper))
    let detail = try decode(ItemDetail.self, from: json.stdout)
    #expect(detail.password == "hunter2")
  }

  @Test func getWithFieldPrintsJustThatValue() throws {
    let item = makeE2ETestItem(title: "GitHub", usernames: ["octocat"], password: "hunter2")
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath, items: [item])
    defer { helper.stop() }

    let text = try LilpwBinary.run(["get", "GitHub", "--field", "password"], extraEnvironment: env(for: helper))
    #expect(text.exitCode == LilpwExitCode.ok.rawValue)
    #expect(text.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hunter2")

    let json = try LilpwBinary.run(
      ["get", "GitHub", "--field", "username", "--json"],
      extraEnvironment: env(for: helper)
    )
    let value = try decode(FieldValue.self, from: json.stdout)
    #expect(value.value == "octocat")
  }

  @Test func readResolvesALilpwReference() throws {
    let item = makeE2ETestItem(title: "GitHub", password: "hunter2")
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath, items: [item])
    defer { helper.stop() }

    let result = try LilpwBinary.run(["read", "lilpw://GitHub/password"], extraEnvironment: env(for: helper))
    #expect(result.exitCode == LilpwExitCode.ok.rawValue)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hunter2")
  }

  @Test func readRejectsAMalformedReference() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath)
    defer { helper.stop() }

    let result = try LilpwBinary.run(["read", "not-a-reference"], extraEnvironment: env(for: helper))
    #expect(result.exitCode == LilpwExitCode.usage.rawValue)
  }

  @Test func totpPrintsASixDigitCode() throws {
    let item = makeE2ETestItem(
      title: "GitHub",
      totpURI: "otpauth://totp/GitHub:octocat?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"
    )
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath, items: [item])
    defer { helper.stop() }

    let result = try LilpwBinary.run(["totp", "GitHub"], extraEnvironment: env(for: helper))
    #expect(result.exitCode == LilpwExitCode.ok.rawValue)
    let code = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(code.count == 6)
    #expect(code.allSatisfy { $0.isNumber })
  }

  @Test func generateWithNoLengthProducesAppleStrongFormat() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath)
    defer { helper.stop() }

    let result = try LilpwBinary.run(["generate"], extraEnvironment: env(for: helper))
    #expect(result.exitCode == LilpwExitCode.ok.rawValue)
    #expect(result.stdout.contains("-"))
  }

  @Test func generateWithLengthProducesACustomPassword() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath)
    defer { helper.stop() }

    let result = try LilpwBinary.run(
      ["generate", "--length", "16", "--no-symbols"],
      extraEnvironment: env(for: helper)
    )
    #expect(result.exitCode == LilpwExitCode.ok.rawValue)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).count == 16)
  }

  // MARK: - Helpers

  private func env(for helper: E2EHelperProcess) -> [String: String] {
    ["LILPW_E2E_MACH_SERVICE_NAME": helper.machServiceName]
  }

  private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
    try LilpwJSONTestDecoding.decoder.decode(type, from: Data(json.utf8))
  }
}

/// Mirrors `LilpwJSON`'s encoder configuration (sorted keys, ISO-8601 dates) on the decoding side
/// — `JSONDecoder`'s `.iso8601` date strategy is what actually matters for round-tripping
/// `AgentStatus`/`ItemSummary`/etc back out of `--json` output; key order doesn't affect decoding.
private enum LilpwJSONTestDecoding {
  static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
