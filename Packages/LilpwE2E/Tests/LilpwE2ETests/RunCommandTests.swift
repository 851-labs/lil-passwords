import Foundation
import LilPasswordsKit
import LilpwCore
import Testing

/// `lilpw run --env KEY=lilpw://item/field -- <cmd>`: 851-2434 specifically calls out env
/// injection and exit-code forwarding as things the E2E suite must cover, since neither is
/// visible from `LilpwRun`'s own unit tests (`LilpwCoreTests`) the same way — those call
/// `LilpwRun.resolveEnvironment`/`LilpwRun.run` directly as plain functions; this suite instead
/// checks what a *child process the real `lilpw` binary execs* actually observes and returns.
@Suite struct RunCommandTests {
  @Test func injectsAResolvedSecretIntoTheChildsEnvironmentWithoutPrintingIt() throws {
    let item = makeE2ETestItem(title: "GitHub", password: "hunter2")
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath, items: [item])
    defer { helper.stop() }

    // `printenv API_TOKEN` only prints the value of that one variable — if injection worked, it's
    // the resolved secret; if `lilpw run` somehow printed the secret itself (rather than only
    // setting it as an environment variable, per `LilpwRun`'s documentation), it would show up a
    // second time in this same stdout, which the exact-equality check below would catch.
    let result = try LilpwBinary.run(
      ["run", "--env", "API_TOKEN=lilpw://GitHub/password", "--", "/usr/bin/printenv", "API_TOKEN"],
      extraEnvironment: env(for: helper)
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hunter2")
  }

  @Test func forwardsTheChildsExactNonzeroExitCode() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath)
    defer { helper.stop() }

    // No --env at all: `LilpwRun.resolveEnvironment([])` never touches the client, so this
    // exercises the helper only incidentally (to prove it's harmless to have one running) — see
    // `noEnvNeverTouchesTheHelperAtAll` below for the case with no helper at all.
    let result = try LilpwBinary.run(
      ["run", "--", "/bin/sh", "-c", "exit 42"],
      extraEnvironment: env(for: helper)
    )
    #expect(result.exitCode == 42)
  }

  @Test func withNoEnvToResolveNeverTouchesTheHelperAtAll() throws {
    // Deliberately no `E2EHelperProcess` at all, and a Mach service name nothing has registered:
    // per `LilpwRun.resolveEnvironment`'s documentation, an empty `--env` list never calls the
    // client, so `lilpw run -- true` must succeed even though "the helper" (as far as this
    // process is concerned) doesn't exist — matching docs/tophat.md's note that this is real,
    // fully-exercised behavior with zero mocking.
    let result = try LilpwBinary.run(
      ["run", "--", "/usr/bin/true"],
      extraEnvironment: ["LILPW_E2E_MACH_SERVICE_NAME": "com.851labs.lilpasswords.e2e.unused-\(UUID())"]
    )
    #expect(result.exitCode == 0)
  }

  @Test func withNoCommandAfterDoubleDashFailsWithUsage() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath)
    defer { helper.stop() }

    let result = try LilpwBinary.run(["run"], extraEnvironment: env(for: helper))
    #expect(result.exitCode == LilpwExitCode.usage.rawValue)
  }

  @Test func aFailingSecretResolutionExitsLockedRatherThanRunningTheCommand() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath, locked: true)
    defer { helper.stop() }

    // The command after `--` (`/bin/sh -c "touch ..."`) must never run: env resolution against a
    // locked vault fails first, so `LilpwRun.run` (and hence the child process) is never reached.
    let sentinel = FileManager.default.temporaryDirectory.appendingPathComponent("lilpw-e2e-should-not-exist-\(UUID())")
    let result = try LilpwBinary.run(
      ["run", "--env", "X=lilpw://anything/password", "--", "/usr/bin/touch", sentinel.path],
      extraEnvironment: env(for: helper)
    )
    #expect(result.exitCode == LilpwExitCode.locked.rawValue)
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
  }

  private func env(for helper: E2EHelperProcess) -> [String: String] {
    ["LILPW_E2E_MACH_SERVICE_NAME": helper.machServiceName]
  }
}
