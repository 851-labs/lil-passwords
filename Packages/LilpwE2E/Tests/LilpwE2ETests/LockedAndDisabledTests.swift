import Foundation
import LilPasswordsKit
import LilpwCore
import Testing

/// `lilpw`'s stable exit codes (``LilpwExitCode``) for the states 851-2434 explicitly calls out:
/// a locked vault, agent access turned off, an unresolvable item, and an ambiguous one — each
/// exercised over a real subprocess-to-helper XPC connection, not just `LilpwCore`'s in-process
/// unit tests.
@Suite struct LockedAndDisabledTests {
  @Test func vaultOperationsWhileLockedFailWithLockedExitCode() throws {
    let item = makeE2ETestItem(title: "GitHub")
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath, items: [item], locked: true)
    defer { helper.stop() }

    let list = try LilpwBinary.run(["list"], extraEnvironment: env(for: helper))
    #expect(list.exitCode == LilpwExitCode.locked.rawValue)
    #expect(!list.stderr.isEmpty)

    let get = try LilpwBinary.run(["get", "GitHub"], extraEnvironment: env(for: helper))
    #expect(get.exitCode == LilpwExitCode.locked.rawValue)
  }

  @Test func statusStillReportsLockedTrueWithoutFailing() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath, locked: true)
    defer { helper.stop() }

    let status = try LilpwBinary.run(["status"], extraEnvironment: env(for: helper))
    #expect(status.exitCode == LilpwExitCode.ok.rawValue)
    #expect(status.stdout.contains("locked: true"))
  }

  @Test func vaultOperationsWithAgentAccessDisabledFailWithItsOwnExitCode() throws {
    let item = makeE2ETestItem(title: "GitHub")
    let helper = try E2EHelperProcess.start(
      helperBinaryPath: LilpwBinary.helperPath,
      items: [item],
      accessDisabled: true
    )
    defer { helper.stop() }

    let list = try LilpwBinary.run(["list"], extraEnvironment: env(for: helper))
    #expect(list.exitCode == LilpwExitCode.agentAccessDisabled.rawValue)

    // status is always answerable regardless of the toggle — it's how a caller would discover
    // *why* every other command is failing.
    let status = try LilpwBinary.run(["status"], extraEnvironment: env(for: helper))
    #expect(status.exitCode == LilpwExitCode.ok.rawValue)
    #expect(status.stdout.contains("agentAccessEnabled: false"))
  }

  @Test func resolvingAnUnknownItemFailsWithNotFound() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath)
    defer { helper.stop() }

    let result = try LilpwBinary.run(["get", "nonexistent"], extraEnvironment: env(for: helper))
    #expect(result.exitCode == LilpwExitCode.notFound.rawValue)
  }

  @Test func resolvingAnAmbiguousItemFailsWithAmbiguous() throws {
    let a = makeE2ETestItem(title: "GitHub Work")
    let b = makeE2ETestItem(title: "GitHub Work")
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath, items: [a, b])
    defer { helper.stop() }

    let result = try LilpwBinary.run(["get", "GitHub Work"], extraEnvironment: env(for: helper))
    #expect(result.exitCode == LilpwExitCode.ambiguous.rawValue)
  }

  @Test func aBadFieldArgumentFailsWithUsage() throws {
    let item = makeE2ETestItem(title: "GitHub")
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath, items: [item])
    defer { helper.stop() }

    let result = try LilpwBinary.run(
      ["get", "GitHub", "--field", "not-a-real-field"], extraEnvironment: env(for: helper))
    #expect(result.exitCode == LilpwExitCode.usage.rawValue)
  }

  @Test func noHelperRegisteredAtAllFailsWithHelperUnreachable() throws {
    // Deliberately never starts an `E2EHelperProcess` — points `lilpw` at a Mach service name
    // nothing has ever registered, which is what a genuinely missing/uninstalled helper looks
    // like from `lilpw`'s side.
    let result = try LilpwBinary.run(
      ["status"],
      extraEnvironment: ["LILPW_E2E_MACH_SERVICE_NAME": "com.851labs.lilpasswords.e2e.nonexistent-\(UUID())"]
    )
    #expect(result.exitCode == LilpwExitCode.helperUnreachable.rawValue)
  }

  private func env(for helper: E2EHelperProcess) -> [String: String] {
    ["LILPW_E2E_MACH_SERVICE_NAME": helper.machServiceName]
  }
}
