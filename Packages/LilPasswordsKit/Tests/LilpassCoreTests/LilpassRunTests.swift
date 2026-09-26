import Foundation
import LilPasswordsKit
import LilpassCore
import Testing

@Suite struct LilpassRunTests {
  // MARK: - parseAssignment

  @Test func parsesAWellFormedAssignment() throws {
    let (key, reference) = try LilpassRun.parseAssignment("API_TOKEN=lilpass://github/password")
    #expect(key == "API_TOKEN")
    #expect(reference.item == "github")
    #expect(reference.field == .password)
  }

  @Test func assignmentValueCanContainAnEqualsSign() throws {
    // Splitting on the *first* `=` matters: a reference's item name could itself contain one, and
    // more importantly this keeps the parser simple/predictable rather than rejecting anything
    // after the first `=`.
    let (key, reference) = try LilpassRun.parseAssignment("KEY=lilpass://a=b/password")
    #expect(key == "KEY")
    #expect(reference.item == "a=b")
  }

  @Test func rejectsAnAssignmentWithNoEqualsSign() {
    #expect(throws: LilpassError.self) {
      _ = try LilpassRun.parseAssignment("lilpass://github/password")
    }
  }

  @Test func rejectsAnAssignmentWithAnEmptyKey() {
    #expect(throws: LilpassError.self) {
      _ = try LilpassRun.parseAssignment("=lilpass://github/password")
    }
  }

  @Test func rejectsAnAssignmentWithAMalformedReference() {
    #expect(throws: LilpassError.self) {
      _ = try LilpassRun.parseAssignment("KEY=not-a-reference")
    }
  }

  @Test func parseFailureExitCodeIsUsage() {
    do {
      _ = try LilpassRun.parseAssignment("nope")
      Issue.record("expected a throw")
    } catch let error as LilpassError {
      #expect(error.exitCode == .usage)
    } catch {
      Issue.record("expected LilpassError, got \(error)")
    }
  }

  // MARK: - resolveEnvironment

  @Test func resolvesEveryAssignmentToItsSecretValue() async throws {
    let item = makeTestItem(title: "GitHub", usernames: ["octocat"], password: "hunter2")
    let harness = try await Harness(items: [item])

    let env = try await LilpassRun.resolveEnvironment(
      ["TOKEN=lilpass://github/password", "USER=lilpass://github/username"],
      client: harness.client
    )
    #expect(env == ["TOKEN": "hunter2", "USER": "octocat"])
  }

  @Test func resolveEnvironmentFailsOnAnUnknownItem() async throws {
    let harness = try await Harness()
    do {
      _ = try await LilpassRun.resolveEnvironment(["TOKEN=lilpass://nonexistent/password"], client: harness.client)
      Issue.record("expected .notFound")
    } catch let error as LilpassError {
      #expect(error.exitCode == .notFound)
    }
  }

  // MARK: - run

  @Test func runForwardsTheChildsEnvironmentAndSucceedsOnExitZero() throws {
    let marker = "LILPASS_RUN_TEST_\(UUID().uuidString.prefix(8))"
    let status = try LilpassRun.run(
      executable: "/bin/sh",
      arguments: ["-c", "[ \"$\(marker)\" = \"present\" ]"],
      env: [marker: "present"]
    )
    #expect(status == 0)
  }

  @Test func runForwardsANonzeroExitCodeUnmodified() throws {
    let status = try LilpassRun.run(executable: "/bin/sh", arguments: ["-c", "exit 42"], env: [:])
    #expect(status == 42)
  }

  @Test func runResolvesTheExecutableAgainstPATH() throws {
    // "true" isn't a path, only a PATH-resolvable name — this exercises the `/usr/bin/env` lookup
    // trick rather than requiring an absolute path.
    let status = try LilpassRun.run(executable: "true", arguments: [], env: [:])
    #expect(status == 0)
  }

  @Test func runReportsANonzeroExitWhenTheExecutableCantBeResolved() throws {
    // `run` always launches `/usr/bin/env <executable>` (see its doc comment) so the executable
    // can be resolved against `PATH` the way a shell would. That means an unresolvable executable
    // is `env`'s failure to resolve it, not a launch failure of `run`'s own `Process` — `env`
    // itself launches fine and exits nonzero (127), so this surfaces as a forwarded exit code, not
    // a thrown `LilpassError`. `LilpassError` is reserved for the much rarer case where
    // `/usr/bin/env` itself can't be launched.
    let status = try LilpassRun.run(executable: "/nonexistent/path/to/nothing", arguments: [], env: [:])
    #expect(status != 0)
  }
}
