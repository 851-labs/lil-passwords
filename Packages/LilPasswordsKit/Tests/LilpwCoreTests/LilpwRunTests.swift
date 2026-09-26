import Foundation
import LilPasswordsKit
import LilpwCore
import Testing

@Suite struct LilpwRunTests {
  // MARK: - parseAssignment

  @Test func parsesAWellFormedAssignment() throws {
    let (key, reference) = try LilpwRun.parseAssignment("API_TOKEN=lilpw://github/password")
    #expect(key == "API_TOKEN")
    #expect(reference.item == "github")
    #expect(reference.field == .password)
  }

  @Test func assignmentValueCanContainAnEqualsSign() throws {
    // Splitting on the *first* `=` matters: a reference's item name could itself contain one, and
    // more importantly this keeps the parser simple/predictable rather than rejecting anything
    // after the first `=`.
    let (key, reference) = try LilpwRun.parseAssignment("KEY=lilpw://a=b/password")
    #expect(key == "KEY")
    #expect(reference.item == "a=b")
  }

  @Test func rejectsAnAssignmentWithNoEqualsSign() {
    #expect(throws: LilpwError.self) {
      _ = try LilpwRun.parseAssignment("lilpw://github/password")
    }
  }

  @Test func rejectsAnAssignmentWithAnEmptyKey() {
    #expect(throws: LilpwError.self) {
      _ = try LilpwRun.parseAssignment("=lilpw://github/password")
    }
  }

  @Test func rejectsAnAssignmentWithAMalformedReference() {
    #expect(throws: LilpwError.self) {
      _ = try LilpwRun.parseAssignment("KEY=not-a-reference")
    }
  }

  @Test func parseFailureExitCodeIsUsage() {
    do {
      _ = try LilpwRun.parseAssignment("nope")
      Issue.record("expected a throw")
    } catch let error as LilpwError {
      #expect(error.exitCode == .usage)
    } catch {
      Issue.record("expected LilpwError, got \(error)")
    }
  }

  // MARK: - resolveEnvironment

  @Test func resolvesEveryAssignmentToItsSecretValue() async throws {
    let item = makeTestItem(title: "GitHub", usernames: ["octocat"], password: "hunter2")
    let harness = try await Harness(items: [item])

    let env = try await LilpwRun.resolveEnvironment(
      ["TOKEN=lilpw://github/password", "USER=lilpw://github/username"],
      client: harness.client
    )
    #expect(env == ["TOKEN": "hunter2", "USER": "octocat"])
  }

  @Test func resolveEnvironmentFailsOnAnUnknownItem() async throws {
    let harness = try await Harness()
    do {
      _ = try await LilpwRun.resolveEnvironment(["TOKEN=lilpw://nonexistent/password"], client: harness.client)
      Issue.record("expected .notFound")
    } catch let error as LilpwError {
      #expect(error.exitCode == .notFound)
    }
  }

  // MARK: - run

  @Test func runForwardsTheChildsEnvironmentAndSucceedsOnExitZero() throws {
    let marker = "LILPW_RUN_TEST_\(UUID().uuidString.prefix(8))"
    let status = try LilpwRun.run(
      executable: "/bin/sh",
      arguments: ["-c", "[ \"$\(marker)\" = \"present\" ]"],
      env: [marker: "present"]
    )
    #expect(status == 0)
  }

  @Test func runForwardsANonzeroExitCodeUnmodified() throws {
    let status = try LilpwRun.run(executable: "/bin/sh", arguments: ["-c", "exit 42"], env: [:])
    #expect(status == 42)
  }

  @Test func runResolvesTheExecutableAgainstPATH() throws {
    // "true" isn't a path, only a PATH-resolvable name — this exercises the `/usr/bin/env` lookup
    // trick rather than requiring an absolute path.
    let status = try LilpwRun.run(executable: "true", arguments: [], env: [:])
    #expect(status == 0)
  }

  @Test func runReportsANonzeroExitWhenTheExecutableCantBeResolved() throws {
    // `run` always launches `/usr/bin/env <executable>` (see its doc comment) so the executable
    // can be resolved against `PATH` the way a shell would. That means an unresolvable executable
    // is `env`'s failure to resolve it, not a launch failure of `run`'s own `Process` — `env`
    // itself launches fine and exits nonzero (127), so this surfaces as a forwarded exit code, not
    // a thrown `LilpwError`. `LilpwError` is reserved for the much rarer case where
    // `/usr/bin/env` itself can't be launched.
    let status = try LilpwRun.run(executable: "/nonexistent/path/to/nothing", arguments: [], env: [:])
    #expect(status != 0)
  }
}
