import Foundation
import LilPasswordsKit
import LilpassCore
import Testing

/// Drives the *built* `lilpass` binary as a real subprocess against a real, disposable
/// `LilpassE2EHelper` over a real cross-process XPC connection (via `E2EHelperProcess`) — not the
/// in-process harness `LilpassCoreTests`/`LilpassMCPTests` use. Covers every command's plain-text
/// stdout, its `--json` output, and its exit code, per 851-2434.
@Suite struct CommandsTests {
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
