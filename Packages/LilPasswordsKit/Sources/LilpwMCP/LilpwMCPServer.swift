import Foundation
import LilPasswordsKit
import LilpwCore
import MCP

/// Builds the `lilpw mcp` server: a stdio MCP server exposing five read-only tools that wrap
/// `LilpwCommands`, the exact same logic layer the `lilpw` CLI itself calls (851-2431).
///
/// Every tool here is read-only (`readOnlyHint: true`) — none of them mutate the vault, matching
/// `lilpw`'s own command set (nothing in 851-2430 writes to the vault either). Every tool's error
/// text is `LilpwError.from(_:).message`, the identical safe-to-print message the CLI writes to
/// stderr for the same failure, satisfying "errors must map to MCP tool errors with the same
/// messages as the CLI." Only the transport differs: an MCP `CallTool.Result(isError: true)`
/// instead of a stderr line plus one of `LilpwExitCode`'s process exit codes.
public enum LilpwMCP {
  /// `lilpw mcp`'s server identity, echoed to clients during `initialize`.
  public static let serverName = "lilpw"
  public static let serverVersion = "1.0.0"

  /// Builds a fully configured `Server` with every tool handler registered, ready for
  /// `server.start(transport:)`. Doesn't start it or pick a transport — the caller (`McpCommand`
  /// for the real CLI, or a test using the SDK's `InMemoryTransport`) owns the transport and
  /// lifecycle.
  ///
  /// `async` because `Server`'s `withMethodHandler` is actor-isolated; awaiting registration here
  /// (rather than firing it off in an unstructured `Task`) guarantees the returned server always
  /// has both handlers registered before any caller can `start(transport:)` it.
  public static func makeServer(client: AgentClient) async -> Server {
    let server = Server(
      name: serverName,
      version: serverVersion,
      capabilities: .init(tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
      ListTools.Result(tools: tools)
    }

    await server.withMethodHandler(CallTool.self) { params in
      await call(params, client: client)
    }

    return server
  }

  // MARK: - Tool definitions

  static let tools: [Tool] = [
    Tool(
      name: "list_passwords",
      description: """
        List every password item in the vault: title, usernames, websites, group, and whether it \
        has a verification code. Never includes password values or notes — use get_password for \
        those. Optionally filter to one category (the item's group/folder).
        """,
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "category": .object([
            "type": "string",
            "description": "Only return items whose group/folder matches this, case-insensitively.",
          ])
        ]),
      ]),
      annotations: Tool.Annotations(title: "List passwords", readOnlyHint: true, openWorldHint: false)
    ),
    Tool(
      name: "search_passwords",
      description: """
        Search password items by a substring of their title, username, or website. Returns the \
        same non-secret summary as list_passwords, not full records.
        """,
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "query": .object([
            "type": "string",
            "description": "Search text to match against item titles, usernames, and websites.",
          ])
        ]),
        "required": .array(["query"]),
      ]),
      annotations: Tool.Annotations(title: "Search passwords", readOnlyHint: true, openWorldHint: false)
    ),
    Tool(
      name: "get_password",
      description: """
        Get the full record for one password item, including its password and notes. Identify the \
        item by title, id, or any other identifier lilpw's item resolver accepts. Fails if no item \
        matches, or if more than one item matches (rather than guessing which one you meant).
        """,
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "item": .object([
            "type": "string",
            "description": "The item's title, id, or other identifier.",
          ])
        ]),
        "required": .array(["item"]),
      ]),
      annotations: Tool.Annotations(title: "Get password", readOnlyHint: true, openWorldHint: false)
    ),
    Tool(
      name: "get_verification_code",
      description: """
        Get a fresh time-based one-time verification code (TOTP) for a password item. Fails if the \
        item has no verification code configured.
        """,
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "item": .object([
            "type": "string",
            "description": "The item's title, id, or other identifier.",
          ])
        ]),
        "required": .array(["item"]),
      ]),
      annotations: Tool.Annotations(title: "Get verification code", readOnlyHint: true, openWorldHint: false)
    ),
    Tool(
      name: "generate_password",
      description: """
        Generate a new random password without saving it anywhere. Without a length, generates \
        Apple's "Strong Password" format; with a length, generates a custom password of that many \
        characters, optionally excluding symbols.
        """,
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "length": .object([
            "type": "integer",
            "description": "Password length. Omit to use Apple's \"Strong Password\" format instead.",
          ]),
          "noSymbols": .object([
            "type": "boolean",
            "description": "Exclude symbols from the generated password. Only used when length is set.",
          ]),
        ]),
      ]),
      annotations: Tool.Annotations(title: "Generate password", readOnlyHint: true, openWorldHint: false)
    ),
  ]

  // MARK: - Dispatch

  /// A generated password's JSON shape — `LilpwCommands.generate` itself just returns a bare
  /// `String`, but every other tool here returns a JSON object, so this wraps it for consistency
  /// rather than returning an unstructured string as this tool's only exception.
  private struct GeneratedPassword: Codable, Sendable {
    let password: String
  }

  private static func call(_ params: CallTool.Parameters, client: AgentClient) async -> CallTool.Result {
    do {
      switch params.name {
      case "list_passwords":
        let category = params.arguments?["category"]?.stringValue
        let items = try await LilpwCommands.list(client: client, category: category)
        return try encoded(items)

      case "search_passwords":
        let query = try requireString("query", from: params)
        let items = try await LilpwCommands.search(client: client, query: query)
        return try encoded(items)

      case "get_password":
        let item = try requireString("item", from: params)
        let detail = try await LilpwCommands.getDetail(client: client, identifier: item)
        return try encoded(detail)

      case "get_verification_code":
        let item = try requireString("item", from: params)
        let code = try await LilpwCommands.totp(client: client, identifier: item)
        return try encoded(code)

      case "generate_password":
        let length = params.arguments?["length"].flatMap { Int($0) }
        let noSymbols = params.arguments?["noSymbols"]?.boolValue ?? false
        let password = try await LilpwCommands.generate(client: client, length: length, noSymbols: noSymbols)
        return try encoded(GeneratedPassword(password: password))

      default:
        return errorResult("Unknown tool: \(params.name)")
      }
    } catch {
      return errorResult(LilpwError.from(error).message)
    }
  }

  /// Reads a required, non-empty string argument, throwing a `LilpwError` (mapped to the same
  /// "usage" exit-code family the CLI would use for a bad argument) if it's missing or blank.
  private static func requireString(_ key: String, from params: CallTool.Parameters) throws -> String {
    guard let value = params.arguments?[key]?.stringValue, !value.isEmpty else {
      throw LilpwError(exitCode: .usage, message: "\(params.name) requires a non-empty \"\(key)\" argument")
    }
    return value
  }

  private static func encoded<T: Encodable>(_ value: T) throws -> CallTool.Result {
    guard let json = LilpwJSON.string(value) else {
      return errorResult("failed to encode tool result")
    }
    return CallTool.Result(content: [.text(text: json, annotations: nil, _meta: nil)], isError: false)
  }

  private static func errorResult(_ message: String) -> CallTool.Result {
    CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
  }
}
