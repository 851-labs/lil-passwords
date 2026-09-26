import Foundation
import LilPasswordsKit
import LilpassCore
import Testing

/// `lilpass run --env KEY=lilpass://item/field -- <cmd>`: 851-2434 specifically calls out env
/// injection and exit-code forwarding as things the E2E suite must cover, since neither is
/// visible from `LilpassRun`'s own unit tests (`LilpassCoreTests`) the same way — those call
/// `LilpassRun.resolveEnvironment`/`LilpassRun.run` directly as plain functions; this suite instead
/// checks what a *child process the real `lilpass` binary execs* actually observes and returns.
///
/// `.timeLimit(.minutes(1))`: every test here talks to a real subprocess over real XPC, and
/// this suite has twice hung a CI job for its full 30-minute timeout with zero output when one
/// of those calls never returned — a per-test time limit turns that into a fast, attributable
/// failure (naming exactly which test timed out) instead of another silent freeze.
@Suite(.timeLimit(.minutes(1)))
struct RunCommandTests {
  @Test func injectsAResolvedSecretIntoTheChildsEnvironmentWithoutPrintingIt() throws {
    let item = makeE2ETestItem(title: "GitHub", password: "hunter2")
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath, items: [item])
    defer { helper.stop() }

    // `printenv API_TOKEN` only prints the value of that one variable — if injection worked, it's
    // the resolved secret; if `lilpass run` somehow printed the secret itself (rather than only
    // setting it as an environment variable, per `LilpassRun`'s documentation), it would show up a
    // second time in this same stdout, which the exact-equality check below would catch.
    let result = try LilpassBinary.run(
      ["run", "--env", "API_TOKEN=lilpass://GitHub/password", "--", "/usr/bin/printenv", "API_TOKEN"],
      extraEnvironment: env(for: helper)
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hunter2")
  }

  @Test func forwardsTheChildsExactNonzeroExitCode() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath)
    defer { helper.stop() }

    // No --env at all: `LilpassRun.resolveEnvironment([])` never touches the client, so this
    // exercises the helper only incidentally (to prove it's harmless to have one running) — see
    // `noEnvNeverTouchesTheHelperAtAll` below for the case with no helper at all.
    let result = try LilpassBinary.run(
      ["run", "--", "/bin/sh", "-c", "exit 42"],
      extraEnvironment: env(for: helper)
    )
    #expect(result.exitCode == 42)
  }

  @Test func withNoEnvToResolveNeverTouchesTheHelperAtAll() throws {
    // Deliberately no `E2EHelperProcess` at all, and a Mach service name nothing has registered:
    // per `LilpassRun.resolveEnvironment`'s documentation, an empty `--env` list never calls the
    // client, so `lilpass run -- true` must succeed even though "the helper" (as far as this
    // process is concerned) doesn't exist — matching docs/tophat.md's note that this is real,
    // fully-exercised behavior with zero mocking.
    let result = try LilpassBinary.run(
      ["run", "--", "/usr/bin/true"],
      extraEnvironment: ["LILPASS_E2E_MACH_SERVICE_NAME": "com.851labs.lilpasswords.e2e.unused-\(UUID())"]
    )
    #expect(result.exitCode == 0)
  }

  @Test func withNoCommandAfterDoubleDashFailsWithUsage() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath)
    defer { helper.stop() }

    let result = try LilpassBinary.run(["run"], extraEnvironment: env(for: helper))
    #expect(result.exitCode == LilpassExitCode.usage.rawValue)
  }

  @Test func aFailingSecretResolutionExitsLockedRatherThanRunningTheCommand() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath, locked: true)
    defer { helper.stop() }

    // The command after `--` (`/bin/sh -c "touch ..."`) must never run: env resolution against a
    // locked vault fails first, so `LilpassRun.run` (and hence the child process) is never reached.
    let sentinel = FileManager.default.temporaryDirectory.appendingPathComponent(
      "lilpass-e2e-should-not-exist-\(UUID())")
    let result = try LilpassBinary.run(
      ["run", "--env", "X=lilpass://anything/password", "--", "/usr/bin/touch", sentinel.path],
      extraEnvironment: env(for: helper)
    )
    #expect(result.exitCode == LilpassExitCode.locked.rawValue)
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
  }

  private func env(for helper: E2EHelperProcess) -> [String: String] {
    ["LILPASS_E2E_MACH_SERVICE_NAME": helper.machServiceName]
  }
}
