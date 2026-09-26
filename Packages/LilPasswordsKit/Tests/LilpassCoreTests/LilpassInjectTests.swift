import Foundation
import LilPasswordsKit
import LilpassCore
import Testing

@Suite struct LilpassInjectTests {
  @Test func replacesASinglePlaceholder() async throws {
    let item = makeTestItem(title: "GitHub", password: "hunter2")
    let harness = try await Harness(items: [item])

    let output = try await LilpassInject.inject(
      template: "TOKEN={{ lilpass://github/password }}\n",
      client: harness.client
    )
    #expect(output == "TOKEN=hunter2\n")
  }

  @Test func replacesMultiplePlaceholdersOnDifferentLines() async throws {
    let item = makeTestItem(title: "GitHub", usernames: ["octocat"], password: "hunter2")
    let harness = try await Harness(items: [item])

    let template = """
      USER={{lilpass://github/username}}
      PASS={{ lilpass://github/password }}
      """
    let output = try await LilpassInject.inject(template: template, client: harness.client)
    #expect(
      output == """
        USER=octocat
        PASS=hunter2
        """)
  }

  @Test func toleratesTwoPlaceholdersOnTheSameLine() async throws {
    let item = makeTestItem(title: "GitHub", usernames: ["octocat"], password: "hunter2")
    let harness = try await Harness(items: [item])

    let output = try await LilpassInject.inject(
      template: "{{lilpass://github/username}}:{{lilpass://github/password}}",
      client: harness.client
    )
    #expect(output == "octocat:hunter2")
  }

  @Test func leavesNonPlaceholderTextUntouched() async throws {
    let harness = try await Harness()
    let output = try await LilpassInject.inject(template: "no placeholders here", client: harness.client)
    #expect(output == "no placeholders here")
  }

  @Test func failsAtomicallyWhenAnyPlaceholderIsUnresolvable() async throws {
    let item = makeTestItem(title: "GitHub", password: "hunter2")
    let harness = try await Harness(items: [item])

    let template = "GOOD={{ lilpass://github/password }}\nBAD={{ lilpass://nonexistent/password }}\n"
    do {
      _ = try await LilpassInject.inject(template: template, client: harness.client)
      Issue.record("expected a throw")
    } catch let error as LilpassError {
      #expect(error.exitCode == .notFound)
    }
  }

  @Test func rejectsAMalformedReferenceInsideAPlaceholder() async throws {
    let harness = try await Harness()
    do {
      _ = try await LilpassInject.inject(template: "{{ lilpass://github }}", client: harness.client)
      Issue.record("expected .usage")
    } catch let error as LilpassError {
      #expect(error.exitCode == .usage)
    }
  }
}
