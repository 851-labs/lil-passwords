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

  @Test func listToolsAdvertisesAllFiveToolsAsReadOnly() async throws {
    let harness = try await Harness()
    let client = try await connectedClient(to: harness)

    let (tools, _) = try await client.listTools()
    #expect(
      Set(tools.map(\.name)) == [
        "list_passwords", "search_passwords", "get_password", "get_verification_code", "generate_password",
      ])
    for tool in tools {
      #expect(tool.annotations.readOnlyHint == true)
    }
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
