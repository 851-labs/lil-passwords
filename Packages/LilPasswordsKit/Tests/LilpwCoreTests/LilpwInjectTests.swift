import Foundation
import LilPasswordsKit
import LilpwCore
import Testing

@Suite struct LilpwInjectTests {
  @Test func replacesASinglePlaceholder() async throws {
    let item = makeTestItem(title: "GitHub", password: "hunter2")
    let harness = try await Harness(items: [item])

    let output = try await LilpwInject.inject(
      template: "TOKEN={{ lilpw://github/password }}\n",
      client: harness.client
    )
    #expect(output == "TOKEN=hunter2\n")
  }

  @Test func replacesMultiplePlaceholdersOnDifferentLines() async throws {
    let item = makeTestItem(title: "GitHub", usernames: ["octocat"], password: "hunter2")
    let harness = try await Harness(items: [item])

    let template = """
      USER={{lilpw://github/username}}
      PASS={{ lilpw://github/password }}
      """
    let output = try await LilpwInject.inject(template: template, client: harness.client)
    #expect(
      output == """
        USER=octocat
        PASS=hunter2
        """)
  }

  @Test func toleratesTwoPlaceholdersOnTheSameLine() async throws {
    let item = makeTestItem(title: "GitHub", usernames: ["octocat"], password: "hunter2")
    let harness = try await Harness(items: [item])

    let output = try await LilpwInject.inject(
      template: "{{lilpw://github/username}}:{{lilpw://github/password}}",
      client: harness.client
    )
    #expect(output == "octocat:hunter2")
  }

  @Test func leavesNonPlaceholderTextUntouched() async throws {
    let harness = try await Harness()
    let output = try await LilpwInject.inject(template: "no placeholders here", client: harness.client)
    #expect(output == "no placeholders here")
  }

  @Test func failsAtomicallyWhenAnyPlaceholderIsUnresolvable() async throws {
    let item = makeTestItem(title: "GitHub", password: "hunter2")
    let harness = try await Harness(items: [item])

    let template = "GOOD={{ lilpw://github/password }}\nBAD={{ lilpw://nonexistent/password }}\n"
    do {
      _ = try await LilpwInject.inject(template: template, client: harness.client)
      Issue.record("expected a throw")
    } catch let error as LilpwError {
      #expect(error.exitCode == .notFound)
    }
  }

  @Test func rejectsAMalformedReferenceInsideAPlaceholder() async throws {
    let harness = try await Harness()
    do {
      _ = try await LilpwInject.inject(template: "{{ lilpw://github }}", client: harness.client)
      Issue.record("expected .usage")
    } catch let error as LilpwError {
      #expect(error.exitCode == .usage)
    }
  }
}
