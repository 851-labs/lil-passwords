import Foundation
import LilPasswordsKit

/// The logic behind every `lilpw` subcommand except `run` (`LilpwRun`) and `inject`
/// (`LilpwInject`), which get their own files.
///
/// Every function here takes an already-connected `AgentClient` and returns a plain `Codable`
/// result (or throws `LilpwError`) — no printing, no `--json` formatting, no exit-code handling.
/// That's the CLI target's job (it decides text vs. JSON and calls `exit(_:)`), which is what
/// makes this testable against an in-process `AgentServer` + `InMemoryVaultStore` the way
/// `AgentXPCEndToEndTests` already tests `AgentServer` itself.
public enum LilpwCommands {
  public static func status(client: AgentClient) async throws -> AgentStatus {
    do {
      return try await client.status()
    } catch {
      throw LilpwError.from(error)
    }
  }

  /// - Parameter category: If non-`nil`, only items whose `PasswordItem.group` case-insensitively
  ///   equals this are returned. `PasswordItem` has no dedicated "category" field — `group` (the
  ///   folder an item belongs to) is the closest existing concept, and `list --category` filters
  ///   on it.
  public static func list(client: AgentClient, category: String?) async throws -> [ItemSummary] {
    do {
      let items = try await client.list()
      return filtered(items, byCategory: category).map(ItemSummary.init)
    } catch {
      throw LilpwError.from(error)
    }
  }

  public static func search(client: AgentClient, query: String) async throws -> [ItemSummary] {
    do {
      let items = try await client.search(query)
      return items.map(ItemSummary.init)
    } catch {
      throw LilpwError.from(error)
    }
  }

  /// `lilpw get <item>` with no `--field`: the full, secret-including record.
  public static func getDetail(client: AgentClient, identifier: String) async throws -> ItemDetail {
    let item = try await resolveItem(identifier, client: client)
    return ItemDetail(item)
  }

  /// `lilpw get <item> --field <field>`: just that one field's value.
  public static func getField(client: AgentClient, identifier: String, field: ItemField) async throws -> FieldValue {
    let item = try await resolveItem(identifier, client: client)
    let value = try await SecretResolver.value(for: field, in: item, client: client)
    return FieldValue(item: item.title, field: field, value: value)
  }

  /// `lilpw read lilpw://<item>/<field>`.
  public static func read(client: AgentClient, reference: SecretReference) async throws -> FieldValue {
    let item = try await resolveItem(reference.item, client: client)
    let value = try await SecretResolver.value(for: reference.field, in: item, client: client)
    return FieldValue(item: item.title, field: reference.field, value: value)
  }

  public static func totp(client: AgentClient, identifier: String) async throws -> TOTPCodeResult {
    let item = try await resolveItem(identifier, client: client)
    do {
      return try await client.totpCode(.id(item.id))
    } catch {
      throw LilpwError.from(error)
    }
  }

  /// - Parameters:
  ///   - length: If non-`nil`, generates a `.custom(length:characterCategories:)` password of this
  ///     length. If `nil`, generates Apple's "Strong Password" format (`.appleStrong`), ignoring
  ///     `noSymbols`.
  ///   - noSymbols: Only consulted when `length` is non-`nil`: excludes symbols from the character
  ///     set when `true`.
  public static func generate(client: AgentClient, length: Int?, noSymbols: Bool) async throws -> String {
    let format: PasswordGenerator.Format
    if let length {
      format = .custom(length: length, characterCategories: noSymbols ? .noSymbols : .all)
    } else {
      format = .appleStrong
    }
    do {
      return try await client.generatePassword(format: format)
    } catch {
      throw LilpwError.from(error)
    }
  }

  /// Shared by every command that needs to resolve exactly one item: fetches the full list once
  /// and resolves `identifier` against it with `ItemResolver`. `LilpwRun` and `LilpwInject` call
  /// this directly for each `lilpw://` reference they need to resolve.
  public static func resolveItem(_ identifier: String, client: AgentClient) async throws -> PasswordItem {
    let items: [PasswordItem]
    do {
      items = try await client.list()
    } catch {
      throw LilpwError.from(error)
    }
    return try ItemResolver.resolve(identifier, in: items)
  }

  private static func filtered(_ items: [PasswordItem], byCategory category: String?) -> [PasswordItem] {
    guard let category else { return items }
    let normalized = category.lowercased()
    return items.filter { ($0.group ?? "").lowercased() == normalized }
  }
}
