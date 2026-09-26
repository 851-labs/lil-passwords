import Foundation
import LilPasswordsKit
import LilpassCore
import MCP
import Testing

@testable import LilpassMCP

/// Drives `LilpassMCP.makeServer(client:)` over a real JSON-RPC round trip using the SDK's own
/// `InMemoryTransport` and `Client` — the protocol-level equivalent of `LilpassCoreTests`' in-process
/// `AgentServer` harness. This exercises the exact wire path a real `claude mcp add`-configured
/// client would use (`initialize`, `tools/list`, `tools/call`), just without spawning the `lilpass`
/// binary or going over stdio.
@Suite struct LilpassMCPServerTests {
  /// Connects a fresh `Client` to a `LilpassMCP` server backed by `harness.client`, ready for
  /// `listTools`/`callTool`.
  private func connectedClient(to harness: Harness) async throws -> Client {
    let server = await LilpassMCP.makeServer(client: harness.client)
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)

    let client = Client(name: "test-client", version: "1.0.0")
    _ = try await client.connect(transport: clientTransport)
    return client
  }

  @Test func listToolsAdvertisesTheFiveOriginalToolsAsReadOnly() async throws {
    let harness = try await Harness()
    let client = try await connectedClient(to: harness)

    let (tools, _) = try await client.listTools()
    #expect(
      Set(tools.map(\.name)) == [
        "list_passwords", "search_passwords", "get_password", "get_verification_code", "generate_password",
        "create_password", "update_password", "delete_password",
      ])

    let readOnlyToolNames: Set = [
      "list_passwords", "search_passwords", "get_password", "get_verification_code", "generate_password",
    ]
    for tool in tools where readOnlyToolNames.contains(tool.name) {
      #expect(tool.annotations.readOnlyHint == true)
    }
  }

  @Test func writeToolsAreAdvertisedAsNotReadOnlyWithCorrectDestructiveHints() async throws {
    let harness = try await Harness()
    let client = try await connectedClient(to: harness)

    let (tools, _) = try await client.listTools()
    let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })

    let create = try #require(byName["create_password"])
    #expect(create.annotations.readOnlyHint == false)
    #expect(create.annotations.destructiveHint == false)

    let update = try #require(byName["update_password"])
    #expect(update.annotations.readOnlyHint == false)
    #expect(update.annotations.destructiveHint == true)

    let delete = try #require(byName["delete_password"])
    #expect(delete.annotations.readOnlyHint == false)
    #expect(delete.annotations.destructiveHint == true)
  }

  @Test func listPasswordsReturnsSummariesWithoutSecrets() async throws {
    let item = makeTestItem(title: "GitHub", notes: "very secret notes")
    let harness = try await Harness(items: [item])
    let client = try await connectedClient(to: harness)

    let (content, isError) = try await client.callTool(name: "list_passwords")
    #expect(isError == false)
    let json = try #require(text(of: content))
    #expect(json.contains("GitHub"))
    #expect(!json.contains("very secret notes"))
  }

  @Test func listPasswordsFiltersByCategory() async throws {
    let work = makeTestItem(title: "Work Mail", group: "Work")
    let personal = makeTestItem(title: "Personal Mail", group: "Personal")
    let harness = try await Harness(items: [work, personal])
    let client = try await connectedClient(to: harness)

    let (content, isError) = try await client.callTool(
      name: "list_passwords", arguments: ["category": "work"])
    #expect(isError == false)
    let json = try #require(text(of: content))
    #expect(json.contains("Work Mail"))
    #expect(!json.contains("Personal Mail"))
  }

  @Test func searchPasswordsDelegatesToFreeTextSearch() async throws {
    let item = makeTestItem(title: "GitHub", usernames: ["octocat"])
    let harness = try await Harness(items: [item])
    let client = try await connectedClient(to: harness)

    let (content, isError) = try await client.callTool(
      name: "search_passwords", arguments: ["query": "octocat"])
    #expect(isError == false)
    let json = try #require(text(of: content))
    #expect(json.contains("GitHub"))
  }

  @Test func getPasswordReturnsTheFullRecord() async throws {
    let item = makeTestItem(title: "GitHub", password: "hunter2", notes: "backup codes: 1234")
    let harness = try await Harness(items: [item])
    let client = try await connectedClient(to: harness)

    let (content, isError) = try await client.callTool(name: "get_password", arguments: ["item": "GitHub"])
    #expect(isError == false)
    let json = try #require(text(of: content))
    #expect(json.contains("hunter2"))
    #expect(json.contains("backup codes: 1234"))
  }

  @Test func getVerificationCodeReturnsASixDigitCode() async throws {
    let item = makeTestItem(
      title: "GitHub",
      totpURI: "otpauth://totp/GitHub:octocat?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"
    )
    let harness = try await Harness(items: [item])
    let client = try await connectedClient(to: harness)

    let (content, isError) = try await client.callTool(
      name: "get_verification_code", arguments: ["item": "GitHub"])
    #expect(isError == false)
    let json = try #require(text(of: content))
    #expect(json.contains("\"code\""))
  }

  @Test func generatePasswordWithoutALengthProducesAnAppleStrongPassword() async throws {
    let harness = try await Harness()
    let client = try await connectedClient(to: harness)

    let (content, isError) = try await client.callTool(name: "generate_password")
    #expect(isError == false)
    let json = try #require(text(of: content))
    #expect(json.contains("-"))
  }

  @Test func generatePasswordWithALengthProducesACustomPassword() async throws {
    let harness = try await Harness()
    let client = try await connectedClient(to: harness)

    let (content, isError) = try await client.callTool(
      name: "generate_password", arguments: ["length": 16, "noSymbols": true])
    #expect(isError == false)
    let json = try #require(text(of: content))
    let password = try #require(decodePassword(json))
    #expect(password.count == 16)
  }

  // MARK: - Write tools (851-2433)
  //
  // `Harness`'s in-process XPC connection always resolves as the app caller (see its own
  // documentation), so these test the tools' own request/response shape — not the write-access
  // gate itself, which only ever rejects a *non-app* caller and is covered end-to-end, with real
  // synthetic app/CLI callers, by `AgentServerTests`'s write-access matrix.

  @Test func createPasswordAddsAnItemAndReturnsItsSummary() async throws {
    let harness = try await Harness()
    let client = try await connectedClient(to: harness)

    let (content, isError) = try await client.callTool(
      name: "create_password",
      arguments: ["title": "GitHub", "username": ["octocat"], "password": "hunter2", "website": ["github.com"]]
    )
    #expect(isError == false)
    let json = try #require(text(of: content))
    #expect(json.contains("GitHub"))
    #expect(!json.contains("hunter2"))

    let (listContent, _) = try await client.callTool(name: "list_passwords")
    let listJSON = try #require(text(of: listContent))
    #expect(listJSON.contains("GitHub"))
  }

  @Test func createPasswordWithGenerateProducesAPasswordWithoutOneBeingSupplied() async throws {
    let harness = try await Harness()
    let client = try await connectedClient(to: harness)

    let (content, isError) = try await client.callTool(
      name: "create_password", arguments: ["title": "GitHub", "generate": true])
    #expect(isError == false)

    let created = try #require(text(of: content))
    #expect(created.contains("GitHub"))

    let (detailContent, _) = try await client.callTool(name: "get_password", arguments: ["item": "GitHub"])
    let detailJSON = try #require(text(of: detailContent))
    #expect(!detailJSON.contains("\"password\":\"\""))
  }

  @Test func createPasswordWithBothPasswordAndGenerateReturnsAUsageError() async throws {
    let harness = try await Harness()
    let client = try await connectedClient(to: harness)

    let (content, isError) = try await client.callTool(
      name: "create_password",
      arguments: ["title": "GitHub", "password": "hunter2", "generate": true]
    )
    #expect(isError == true)
    let message = try #require(text(of: content))
    #expect(message.contains("password") && message.contains("generate"))
  }

  @Test func createPasswordWithoutATitleReturnsAUsageError() async throws {
    let harness = try await Harness()
    let client = try await connectedClient(to: harness)

    let (content, isError) = try await client.callTool(name: "create_password", arguments: ["password": "hunter2"])
    #expect(isError == true)
    let message = try #require(text(of: content))
    #expect(message.contains("title"))
  }

  @Test func updatePasswordChangesOnlyTheFieldsPassed() async throws {
    let item = makeTestItem(title: "GitHub", usernames: ["octocat"], password: "hunter2", notes: "old notes")
    let harness = try await Harness(items: [item])
    let client = try await connectedClient(to: harness)

    let (content, isError) = try await client.callTool(
      name: "update_password", arguments: ["item": "GitHub", "title": "GitHub Enterprise"])
    #expect(isError == false)
    let json = try #require(text(of: content))
    #expect(json.contains("GitHub Enterprise"))

    let (detailContent, _) = try await client.callTool(
      name: "get_password", arguments: ["item": "GitHub Enterprise"])
    let detailJSON = try #require(text(of: detailContent))
    #expect(detailJSON.contains("hunter2"))
    #expect(detailJSON.contains("old notes"))
  }

  @Test func deletePasswordSoftDeletesTheItem() async throws {
    let item = makeTestItem(title: "GitHub")
    let harness = try await Harness(items: [item])
    let client = try await connectedClient(to: harness)

    let (content, isError) = try await client.callTool(name: "delete_password", arguments: ["item": "GitHub"])
    #expect(isError == false)
    let json = try #require(text(of: content))
    #expect(json.contains("GitHub"))

    let (listContent, _) = try await client.callTool(name: "list_passwords")
    let listJSON = try #require(text(of: listContent))
    #expect(!listJSON.contains("GitHub"))
  }

  @Test func deletePasswordOnAnUnknownItemReturnsTheCLIsNotFoundMessage() async throws {
    let harness = try await Harness()
    let client = try await connectedClient(to: harness)

    let (content, isError) = try await client.callTool(
      name: "delete_password", arguments: ["item": "nonexistent"])
    #expect(isError == true)
    let message = try #require(text(of: content))
    let expected = try await expectedCLIMessage {
      _ = try await LilpassCommands.remove(client: harness.client, identifier: "nonexistent")
    }
    #expect(message == expected)
  }

  // MARK: - Error mapping (same messages as the CLI's `LilpassError`)

  @Test func getPasswordOnAnUnknownItemReturnsTheCLIsNotFoundMessage() async throws {
    let harness = try await Harness()
    let client = try await connectedClient(to: harness)

    let (content, isError) = try await client.callTool(name: "get_password", arguments: ["item": "nonexistent"])
    #expect(isError == true)
    let message = try #require(text(of: content))
    let expected = try await expectedCLIMessage {
      _ = try await LilpassCommands.getDetail(client: harness.client, identifier: "nonexistent")
    }
    #expect(message == expected)
  }

  @Test func getPasswordOnAnAmbiguousItemReturnsTheCLIsAmbiguousMessage() async throws {
    let a = makeTestItem(title: "GitHub Work")
    let b = makeTestItem(title: "GitHub Work")
    let harness = try await Harness(items: [a, b])
    let client = try await connectedClient(to: harness)

    let (content, isError) = try await client.callTool(name: "get_password", arguments: ["item": "GitHub Work"])
    #expect(isError == true)
    let message = try #require(text(of: content))
    let expected = try await expectedCLIMessage {
      _ = try await LilpassCommands.getDetail(client: harness.client, identifier: "GitHub Work")
    }
    #expect(message == expected)
  }

  @Test func vaultOperationsBeforeUnlockReturnTheCLIsLockedMessage() async throws {
    let harness = try await Harness(items: [makeTestItem()], unlocked: false)
    let client = try await connectedClient(to: harness)

    let (content, isError) = try await client.callTool(name: "list_passwords")
    #expect(isError == true)
    let message = try #require(text(of: content))
    let expected = try await expectedCLIMessage {
      _ = try await LilpassCommands.list(client: harness.client, category: nil)
    }
    #expect(message == expected)
  }

  @Test func agentAccessDisabledReturnsTheCLIsOwnMessage() async throws {
    let harness = try await Harness(accessPolicy: AlwaysDenyAccessPolicy())
    let client = try await connectedClient(to: harness)

    let (content, isError) = try await client.callTool(name: "list_passwords")
    #expect(isError == true)
    let message = try #require(text(of: content))
    let expected = try await expectedCLIMessage {
      _ = try await LilpassCommands.list(client: harness.client, category: nil)
    }
    #expect(message == expected)
  }

  @Test func searchPasswordsWithoutAQueryReturnsAUsageError() async throws {
    let harness = try await Harness()
    let client = try await connectedClient(to: harness)

    let (content, isError) = try await client.callTool(name: "search_passwords")
    #expect(isError == true)
    let message = try #require(text(of: content))
    #expect(message.contains("query"))
  }

  // MARK: - Helpers

  private func text(of content: [Tool.Content]) -> String? {
    for item in content {
      if case .text(let text, _, _) = item {
        return text
      }
    }
    return nil
  }

  private struct GeneratedPassword: Decodable {
    let password: String
  }

  private func decodePassword(_ json: String) -> String? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(GeneratedPassword.self, from: data).password
  }

  /// Runs `operation` (a direct `LilpassCommands` call expected to throw) and returns the exact
  /// message `LilpassError.from(_:)` would produce — the same message the CLI prints to stderr for
  /// the same failure, and what an MCP tool error's text should equal.
  private func expectedCLIMessage(_ operation: () async throws -> Void) async throws -> String {
    do {
      try await operation()
      Issue.record("expected operation to throw")
      return ""
    } catch {
      return LilpassError.from(error).message
    }
  }
}
