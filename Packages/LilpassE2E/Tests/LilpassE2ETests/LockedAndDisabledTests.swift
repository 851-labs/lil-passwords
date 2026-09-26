import Foundation
import LilPasswordsKit
import LilpassCore
import Testing

/// `lilpass`'s stable exit codes (``LilpassExitCode``) for the states 851-2434 explicitly calls out:
/// a locked vault, agent access turned off, an unresolvable item, and an ambiguous one — each
/// exercised over a real subprocess-to-helper XPC connection, not just `LilpassCore`'s in-process
/// unit tests.
///
/// `.timeLimit(.minutes(1))`: every test here talks to a real subprocess over real XPC, and
/// this suite has twice hung a CI job for its full 30-minute timeout with zero output when one
/// of those calls never returned — a per-test time limit turns that into a fast, attributable
/// failure (naming exactly which test timed out) instead of another silent freeze.
///
/// `.serialized`: see `MCPStdioSessionTests`'s doc comment and `CommandsTests`'s for the full
/// rationale — a Swift runtime generic-metadata-cache livelock triggered by parallel first-time
/// instantiation of the same generic type, now suspected to be racing across this package's suites
/// rather than only within `MCPStdioSessionTests`.
@Suite(.timeLimit(.minutes(1)), .serialized)
struct LockedAndDisabledTests {
  init() {
    HangWatchdog.arm()
    HangWatchdog.trace("LockedAndDisabledTests.init()")
  }

  @Test func vaultOperationsWhileLockedFailWithLockedExitCode() throws {
    let item = makeE2ETestItem(title: "GitHub")
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath, items: [item], locked: true)
    defer { helper.stop() }

    let list = try LilpassBinary.run(["list"], extraEnvironment: env(for: helper))
    #expect(list.exitCode == LilpassExitCode.locked.rawValue)
    #expect(!list.stderr.isEmpty)

    let get = try LilpassBinary.run(["get", "GitHub"], extraEnvironment: env(for: helper))
    #expect(get.exitCode == LilpassExitCode.locked.rawValue)
  }

  @Test func statusStillReportsLockedTrueWithoutFailing() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath, locked: true)
    defer { helper.stop() }

    let status = try LilpassBinary.run(["status"], extraEnvironment: env(for: helper))
    #expect(status.exitCode == LilpassExitCode.ok.rawValue)
    #expect(status.stdout.contains("locked: true"))
  }

  @Test func vaultOperationsWithAgentAccessDisabledFailWithItsOwnExitCode() throws {
    let item = makeE2ETestItem(title: "GitHub")
    let helper = try E2EHelperProcess.start(
      helperBinaryPath: LilpassBinary.helperPath,
      items: [item],
      accessDisabled: true
    )
    defer { helper.stop() }

    let list = try LilpassBinary.run(["list"], extraEnvironment: env(for: helper))
    #expect(list.exitCode == LilpassExitCode.agentAccessDisabled.rawValue)

    // status is always answerable regardless of the toggle — it's how a caller would discover
    // *why* every other command is failing.
    let status = try LilpassBinary.run(["status"], extraEnvironment: env(for: helper))
    #expect(status.exitCode == LilpassExitCode.ok.rawValue)
    #expect(status.stdout.contains("agentAccessEnabled: false"))
  }

  @Test func resolvingAnUnknownItemFailsWithNotFound() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath)
    defer { helper.stop() }

    let result = try LilpassBinary.run(["get", "nonexistent"], extraEnvironment: env(for: helper))
    #expect(result.exitCode == LilpassExitCode.notFound.rawValue)
  }

  @Test func resolvingAnAmbiguousItemFailsWithAmbiguous() throws {
    let a = makeE2ETestItem(title: "GitHub Work")
    let b = makeE2ETestItem(title: "GitHub Work")
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath, items: [a, b])
    defer { helper.stop() }

    let result = try LilpassBinary.run(["get", "GitHub Work"], extraEnvironment: env(for: helper))
    #expect(result.exitCode == LilpassExitCode.ambiguous.rawValue)
  }

  @Test func aBadFieldArgumentFailsWithUsage() throws {
    let item = makeE2ETestItem(title: "GitHub")
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath, items: [item])
    defer { helper.stop() }

    let result = try LilpassBinary.run(
      ["get", "GitHub", "--field", "not-a-real-field"], extraEnvironment: env(for: helper))
    #expect(result.exitCode == LilpassExitCode.usage.rawValue)
  }

  @Test func noHelperRegisteredAtAllFailsWithHelperUnreachable() throws {
    // Deliberately never starts an `E2EHelperProcess` — points `lilpass` at a Mach service name
    // nothing has ever registered, which is what a genuinely missing/uninstalled helper looks
    // like from `lilpass`'s side.
    let result = try LilpassBinary.run(
      ["status"],
      extraEnvironment: ["LILPASS_E2E_MACH_SERVICE_NAME": "com.851labs.lilpasswords.e2e.nonexistent-\(UUID())"]
    )
    #expect(result.exitCode == LilpassExitCode.helperUnreachable.rawValue)
  }

  private func env(for helper: E2EHelperProcess) -> [String: String] {
    ["LILPASS_E2E_MACH_SERVICE_NAME": helper.machServiceName]
  }
}
