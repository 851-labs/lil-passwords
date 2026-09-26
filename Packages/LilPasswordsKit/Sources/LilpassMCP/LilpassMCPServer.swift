import Foundation
import LilPasswordsKit
import LilpassCore
import MCP

/// Builds the `lilpass mcp` server: a stdio MCP server wrapping `LilpassCommands`, the exact same
/// logic layer the `lilpass` CLI itself calls (851-2431), including the write tools
/// `create_password`/`update_password`/`delete_password` (851-2433).
///
/// The five original tools are read-only (`readOnlyHint: true`) — none of them mutate the vault,
/// matching `lilpass`'s own read-only command set at the time (851-2430). `create_password`/
/// `update_password`/`delete_password` are the only tools with `readOnlyHint: false`; each fails
/// with the same `agentWriteAccessDisabled` message the CLI's `add`/`edit`/`rm` would while
/// Settings → Agents' write-access toggle is off, since they call through the identical
/// `AgentServer` write gate. Every tool's error text is `LilpassError.from(_:).message`, the
/// identical safe-to-print message the CLI writes to stderr for the same failure, satisfying
/// "errors must map to MCP tool errors with the same messages as the CLI." Only the transport
/// differs: an MCP `CallTool.Result(isError: true)` instead of a stderr line plus one of
/// `LilpassExitCode`'s process exit codes.
public enum LilpassMCP {
  /// `lilpass mcp`'s server identity, echoed to clients during `initialize`.
  public static let serverName = LilPasswordsKit.cliName
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
        item by title, id, or any other identifier lilpass's item resolver accepts. Fails if no item \
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
    Tool(
      name: "create_password",
      description: """
        Create a new password item in the vault. Requires agent write access, a separate toggle \
        from read access in Settings → Agents — fails with a clear error while it's off, same as \
        every other write tool here. Supply either "password" or "generate": true (never both). \
        Returns the same non-secret summary as list_passwords, not the password you supplied.
        """,
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "title": .object(["type": "string", "description": "The item's title."]),
          "username": .object([
            "type": "array", "items": .object(["type": "string"]),
            "description": "Usernames or account identifiers for this item.",
          ]),
          "password": .object([
            "type": "string", "description": "The item's password. Omit if generate is true.",
          ]),
          "generate": .object([
            "type": "boolean",
            "description": "Generate a password instead of supplying one. Defaults to false.",
          ]),
          "length": .object([
            "type": "integer", "description": "Exact length when generate is true. Defaults to Apple's format.",
          ]),
          "noSymbols": .object([
            "type": "boolean", "description": "Exclude symbols when generate is true.",
          ]),
          "website": .object([
            "type": "array", "items": .object(["type": "string"]),
            "description": "Website URLs or domains for this item.",
          ]),
          "notes": .object(["type": "string", "description": "Free-text notes."]),
          "group": .object(["type": "string", "description": "The group/folder this item belongs to."]),
        ]),
        "required": .array(["title"]),
      ]),
      annotations: Tool.Annotations(
        title: "Create password", readOnlyHint: false, destructiveHint: false, idempotentHint: false,
        openWorldHint: false
      )
    ),
    Tool(
      name: "update_password",
      description: """
        Update an existing password item. Only the fields you pass are changed — "username" and \
        "website" each replace that field's whole list when given at all. Requires agent write \
        access, same as create_password. Supply either "password" or "generate": true to change \
        the password; omit both to leave it as-is.
        """,
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "item": .object(["type": "string", "description": "The item's title, id, or other identifier."]),
          "title": .object(["type": "string", "description": "Replace the item's title."]),
          "username": .object([
            "type": "array", "items": .object(["type": "string"]),
            "description": "Replace the item's usernames.",
          ]),
          "password": .object(["type": "string", "description": "Replace the item's password."]),
          "generate": .object([
            "type": "boolean", "description": "Generate a new password instead of supplying one.",
          ]),
          "length": .object([
            "type": "integer", "description": "Exact length when generate is true. Defaults to Apple's format.",
          ]),
          "noSymbols": .object([
            "type": "boolean", "description": "Exclude symbols when generate is true.",
          ]),
          "website": .object([
            "type": "array", "items": .object(["type": "string"]),
            "description": "Replace the item's websites.",
          ]),
          "notes": .object(["type": "string", "description": "Replace the item's notes."]),
          "group": .object(["type": "string", "description": "Replace the item's group/folder."]),
        ]),
        "required": .array(["item"]),
      ]),
      annotations: Tool.Annotations(
        title: "Update password", readOnlyHint: false, destructiveHint: true, idempotentHint: false,
        openWorldHint: false
      )
    ),
    Tool(
      name: "delete_password",
      description: """
        Delete a password item. Soft-deletes only — the item moves to Recently Deleted, exactly \
        like deleting it from the app; there is no permanent-delete this tool can reach. Requires \
        agent write access, same as create_password/update_password.
        """,
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "item": .object(["type": "string", "description": "The item's title, id, or other identifier."])
        ]),
        "required": .array(["item"]),
      ]),
      annotations: Tool.Annotations(
        title: "Delete password", readOnlyHint: false, destructiveHint: true, idempotentHint: true,
        openWorldHint: false
      )
    ),
  ]

  // MARK: - Dispatch

  /// A generated password's JSON shape — `LilpassCommands.generate` itself just returns a bare
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
        let items = try await LilpassCommands.list(client: client, category: category)
        return try encoded(items)

      case "search_passwords":
        let query = try requireString("query", from: params)
        let items = try await LilpassCommands.search(client: client, query: query)
        return try encoded(items)

      case "get_password":
        let item = try requireString("item", from: params)
        let detail = try await LilpassCommands.getDetail(client: client, identifier: item)
        return try encoded(detail)

      case "get_verification_code":
        let item = try requireString("item", from: params)
        let code = try await LilpassCommands.totp(client: client, identifier: item)
        return try encoded(code)

      case "generate_password":
        let length = params.arguments?["length"].flatMap { Int($0) }
        let noSymbols = params.arguments?["noSymbols"]?.boolValue ?? false
        let password = try await LilpassCommands.generate(client: client, length: length, noSymbols: noSymbols)
        return try encoded(GeneratedPassword(password: password))

      case "create_password":
        let title = try requireString("title", from: params)
        let password = try await resolvePassword(from: params, client: client)
        let created = try await LilpassCommands.add(
          client: client,
          title: title,
          usernames: stringArray("username", from: params),
          password: password,
          websites: stringArray("website", from: params),
          notes: params.arguments?["notes"]?.stringValue ?? "",
          group: params.arguments?["group"]?.stringValue
        )
        return try encoded(created)

      case "update_password":
        let item = try requireString("item", from: params)
        let password = try await resolveOptionalPassword(from: params, client: client)
        let updated = try await LilpassCommands.edit(
          client: client,
          identifier: item,
          title: params.arguments?["title"]?.stringValue,
          usernames: stringArray("username", from: params),
          password: password,
          websites: stringArray("website", from: params),
          notes: params.arguments?["notes"]?.stringValue,
          group: params.arguments?["group"]?.stringValue
        )
        return try encoded(updated)

      case "delete_password":
        let item = try requireString("item", from: params)
        let removed = try await LilpassCommands.remove(client: client, identifier: item)
        return try encoded(removed)

      default:
        return errorResult("Unknown tool: \(params.name)")
      }
    } catch {
      return errorResult(LilpassError.from(error).message)
    }
  }

  /// Reads a required, non-empty string argument, throwing a `LilpassError` (mapped to the same
  /// "usage" exit-code family the CLI would use for a bad argument) if it's missing or blank.
  private static func requireString(_ key: String, from params: CallTool.Parameters) throws -> String {
    guard let value = params.arguments?[key]?.stringValue, !value.isEmpty else {
      throw LilpassError(exitCode: .usage, message: "\(params.name) requires a non-empty \"\(key)\" argument")
    }
    return value
  }

  /// Reads a `key` array argument as `[String]`, dropping any non-string element rather than
  /// failing the whole call — the same lenient spirit as `requireString`'s "from" reads only what
  /// it needs. Missing entirely reads as empty, matching `create_password`/`update_password`'s
  /// "not given" default for `--username`/`--website`.
  private static func stringArray(_ key: String, from params: CallTool.Parameters) -> [String] {
    params.arguments?[key]?.arrayValue?.compactMap(\.stringValue) ?? []
  }

  /// `create_password`'s password resolution: exactly one of `"password"` or `"generate": true`
  /// must be given, mirroring `AddCommand`'s `validate()` (minus the CLI-only `ps`-leak rationale
  /// for stdin — an MCP tool argument never appears in `ps` output the way a command-line argument
  /// would, so a plain string argument is fine here).
  private static func resolvePassword(
    from params: CallTool.Parameters, client: AgentClient
  ) async throws -> String {
    let generate = params.arguments?["generate"]?.boolValue ?? false
    let explicit = params.arguments?["password"]?.stringValue
    if generate {
      guard explicit == nil else {
        throw LilpassError(exitCode: .usage, message: "\(params.name) can't take both \"password\" and \"generate\"")
      }
      let length = params.arguments?["length"].flatMap { Int($0) }
      let noSymbols = params.arguments?["noSymbols"]?.boolValue ?? false
      return try await LilpassCommands.generate(client: client, length: length, noSymbols: noSymbols)
    }
    guard let explicit, !explicit.isEmpty else {
      throw LilpassError(
        exitCode: .usage, message: "\(params.name) requires either \"password\" or \"generate\": true"
      )
    }
    return explicit
  }

  /// `update_password`'s password resolution: `nil` (leave the password unchanged) unless the
  /// caller passed `"password"` or `"generate": true`.
  private static func resolveOptionalPassword(
    from params: CallTool.Parameters, client: AgentClient
  ) async throws -> String? {
    let generate = params.arguments?["generate"]?.boolValue ?? false
    let explicit = params.arguments?["password"]?.stringValue
    if generate {
      guard explicit == nil else {
        throw LilpassError(exitCode: .usage, message: "\(params.name) can't take both \"password\" and \"generate\"")
      }
      let length = params.arguments?["length"].flatMap { Int($0) }
      let noSymbols = params.arguments?["noSymbols"]?.boolValue ?? false
      return try await LilpassCommands.generate(client: client, length: length, noSymbols: noSymbols)
    }
    return explicit
  }

  private static func encoded<T: Encodable>(_ value: T) throws -> CallTool.Result {
    guard let json = LilpassJSON.string(value) else {
      return errorResult("failed to encode tool result")
    }
    return CallTool.Result(content: [.text(text: json, annotations: nil, _meta: nil)], isError: false)
  }

  private static func errorResult(_ message: String) -> CallTool.Result {
    CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
  }
}
