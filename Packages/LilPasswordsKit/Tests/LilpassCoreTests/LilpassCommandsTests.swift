import Foundation
import LilPasswordsKit
import LilpassCore
import Testing

@Suite struct LilpassCommandsTests {
  @Test func statusReflectsLockStateOverARealXPCConnection() async throws {
    let harness = try await Harness(unlocked: false)
    let status = try await LilpassCommands.status(client: harness.client)
    #expect(status.locked == true)
    #expect(status.agentAccessEnabled == true)
  }

  @Test func listReturnsSummariesWithoutSecrets() async throws {
    let item = makeTestItem(title: "GitHub", notes: "very secret notes")
    let harness = try await Harness(items: [item])

    let summaries = try await LilpassCommands.list(client: harness.client, category: nil)
    #expect(summaries.map(\.id) == [item.id])
    #expect(summaries[0].title == "GitHub")
    // `ItemSummary` structurally has no `password`/`notes` field at all, so there's nothing to
    // assert is empty — the type itself is the guarantee. This test exists to document that.
  }

  @Test func listFiltersByCategory() async throws {
    let work = makeTestItem(title: "Work Mail", group: "Work")
    let personal = makeTestItem(title: "Personal Mail", group: "Personal")
    let harness = try await Harness(items: [work, personal])

    let filtered = try await LilpassCommands.list(client: harness.client, category: "work")
    #expect(filtered.map(\.id) == [work.id])
  }

  @Test func searchDelegatesToTheAgentsFreeTextSearch() async throws {
    let item = makeTestItem(title: "GitHub", usernames: ["octocat"])
    let harness = try await Harness(items: [item])

    let results = try await LilpassCommands.search(client: harness.client, query: "octocat")
    #expect(results.map(\.id) == [item.id])
  }

  @Test func getDetailIncludesThePasswordAndNotes() async throws {
    let item = makeTestItem(title: "GitHub", password: "hunter2", notes: "backup codes: 1234")
    let harness = try await Harness(items: [item])

    let detail = try await LilpassCommands.getDetail(client: harness.client, identifier: "GitHub")
    #expect(detail.password == "hunter2")
    #expect(detail.notes == "backup codes: 1234")
  }

  @Test func getFieldReturnsJustThatField() async throws {
    let item = makeTestItem(title: "GitHub", usernames: ["octocat"], password: "hunter2")
    let harness = try await Harness(items: [item])

    let password = try await LilpassCommands.getField(client: harness.client, identifier: "GitHub", field: .password)
    #expect(password.value == "hunter2")

    let username = try await LilpassCommands.getField(client: harness.client, identifier: "GitHub", field: .username)
    #expect(username.value == "octocat")
  }

  @Test func getFieldOnAWebsitelessItemFailsWithNotFound() async throws {
    let item = makeTestItem(title: "GitHub", websites: [])
    let harness = try await Harness(items: [item])

    do {
      _ = try await LilpassCommands.getField(client: harness.client, identifier: "GitHub", field: .website)
      Issue.record("expected .notFound")
    } catch let error as LilpassError {
      #expect(error.exitCode == .notFound)
    }
  }

  @Test func readResolvesASecretReference() async throws {
    let item = makeTestItem(title: "GitHub", password: "hunter2")
    let harness = try await Harness(items: [item])

    let reference = try #require(SecretReference(string: "lilpass://github/password"))
    let value = try await LilpassCommands.read(client: harness.client, reference: reference)
    #expect(value.value == "hunter2")
  }

  @Test func totpReturnsASixDigitCode() async throws {
    let item = makeTestItem(
      title: "GitHub",
      totpURI: "otpauth://totp/GitHub:octocat?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"
    )
    let harness = try await Harness(items: [item])

    let result = try await LilpassCommands.totp(client: harness.client, identifier: "GitHub")
    #expect(result.code.count == 6)
  }

  @Test func generateWithNoLengthProducesAnAppleStrongPassword() async throws {
    let harness = try await Harness()
    let password = try await LilpassCommands.generate(client: harness.client, length: nil, noSymbols: false)
    #expect(password.contains("-"))
  }

  @Test func generateWithALengthProducesACustomPassword() async throws {
    let harness = try await Harness()
    let password = try await LilpassCommands.generate(client: harness.client, length: 16, noSymbols: true)
    #expect(password.count == 16)
  }

  // MARK: - Write commands (851-2433)
  //
  // `Harness`'s in-process XPC connection always resolves as the app caller (see its own
  // documentation), so these test `add`/`edit`/`remove`'s own logic — not the write-access gate
  // itself, which only ever rejects a *non-app* caller and is covered end-to-end, with real
  // synthetic app/CLI callers, by `AgentServerTests`'s write-access matrix.

  @Test func addCreatesANewItemAndReturnsItsSummary() async throws {
    let harness = try await Harness()

    let created = try await LilpassCommands.add(
      client: harness.client,
      title: "GitHub",
      usernames: ["octocat"],
      password: "hunter2",
      websites: ["github.com"],
      notes: "",
      group: nil
    )
    #expect(created.title == "GitHub")
    #expect(created.usernames == ["octocat"])
    #expect(created.websites == ["https://github.com"])

    let listed = try await LilpassCommands.list(client: harness.client, category: nil)
    #expect(listed.map(\.id) == [created.id])

    let detail = try await LilpassCommands.getDetail(client: harness.client, identifier: "GitHub")
    #expect(detail.password == "hunter2")
  }

  @Test func addRejectsAWebsiteThatDoesNotParseIntoAURLWithAHost() async throws {
    let harness = try await Harness()
    do {
      _ = try await LilpassCommands.add(
        client: harness.client,
        title: "GitHub",
        usernames: [],
        password: "hunter2",
        websites: ["   "],
        notes: "",
        group: nil
      )
      Issue.record("expected a usage error")
    } catch let error as LilpassError {
      #expect(error.exitCode == .usage)
    }
  }

  @Test func editChangesOnlyTheFieldsPassed() async throws {
    let item = makeTestItem(title: "GitHub", usernames: ["octocat"], password: "hunter2", notes: "old notes")
    let harness = try await Harness(items: [item])

    let updated = try await LilpassCommands.edit(
      client: harness.client,
      identifier: "GitHub",
      title: "GitHub Enterprise",
      usernames: [],
      password: nil,
      websites: [],
      notes: nil,
      group: nil
    )
    #expect(updated.title == "GitHub Enterprise")

    let detail = try await LilpassCommands.getDetail(client: harness.client, identifier: "GitHub Enterprise")
    #expect(detail.password == "hunter2")
    #expect(detail.notes == "old notes")
    #expect(detail.usernames == ["octocat"])
  }

  @Test func editReplacesThePasswordWhenOneIsGiven() async throws {
    let item = makeTestItem(title: "GitHub", password: "hunter2")
    let harness = try await Harness(items: [item])

    _ = try await LilpassCommands.edit(
      client: harness.client,
      identifier: "GitHub",
      title: nil,
      usernames: [],
      password: "new-password",
      websites: [],
      notes: nil,
      group: nil
    )

    let detail = try await LilpassCommands.getDetail(client: harness.client, identifier: "GitHub")
    #expect(detail.password == "new-password")
  }

  @Test func editOnAnUnknownItemMapsToNotFound() async throws {
    let harness = try await Harness()
    do {
      _ = try await LilpassCommands.edit(
        client: harness.client, identifier: "nonexistent", title: "x", usernames: [], password: nil, websites: [],
        notes: nil, group: nil
      )
      Issue.record("expected .notFound")
    } catch let error as LilpassError {
      #expect(error.exitCode == .notFound)
    }
  }

  @Test func removeSoftDeletesTheItemAndReturnsItsPreDeletionSummary() async throws {
    let item = makeTestItem(title: "GitHub")
    let harness = try await Harness(items: [item])

    let removed = try await LilpassCommands.remove(client: harness.client, identifier: "GitHub")
    #expect(removed.id == item.id)
    #expect(removed.title == "GitHub")

    do {
      _ = try await LilpassCommands.getDetail(client: harness.client, identifier: "GitHub")
      Issue.record("expected .notFound after removal")
    } catch let error as LilpassError {
      #expect(error.exitCode == .notFound)
    }
  }

  // MARK: - Exit code mapping

  @Test func vaultOperationsBeforeUnlockMapToTheLockedExitCode() async throws {
    let harness = try await Harness(items: [makeTestItem()], unlocked: false)
    do {
      _ = try await LilpassCommands.list(client: harness.client, category: nil)
      Issue.record("expected .locked")
    } catch let error as LilpassError {
      #expect(error.exitCode == .locked)
    }
  }

  @Test func agentAccessDisabledMapsToItsOwnExitCode() async throws {
    let harness = try await Harness(accessPolicy: AlwaysDenyAccessPolicy())
    do {
      _ = try await LilpassCommands.status(client: harness.client)
      // status is always answerable regardless of the toggle.
    } catch {
      Issue.record("status should never fail: \(error)")
    }
    do {
      _ = try await LilpassCommands.list(client: harness.client, category: nil)
      Issue.record("expected .agentAccessDisabled")
    } catch let error as LilpassError {
      #expect(error.exitCode == .agentAccessDisabled)
    }
  }

  @Test func resolvingAnUnknownItemMapsToNotFound() async throws {
    let harness = try await Harness()
    do {
      _ = try await LilpassCommands.getDetail(client: harness.client, identifier: "nonexistent")
      Issue.record("expected .notFound")
    } catch let error as LilpassError {
      #expect(error.exitCode == .notFound)
    }
  }

  @Test func resolvingAnAmbiguousItemMapsToAmbiguous() async throws {
    let a = makeTestItem(title: "GitHub Work")
    let b = makeTestItem(title: "GitHub Work")
    let harness = try await Harness(items: [a, b])
    do {
      _ = try await LilpassCommands.getDetail(client: harness.client, identifier: "GitHub Work")
      Issue.record("expected .ambiguous")
    } catch let error as LilpassError {
      #expect(error.exitCode == .ambiguous)
    }
  }
}
