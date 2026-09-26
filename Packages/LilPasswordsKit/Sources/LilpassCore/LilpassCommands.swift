import Foundation
import LilPasswordsKit

/// The logic behind every `lilpass` subcommand except `run` (`LilpassRun`) and `inject`
/// (`LilpassInject`), which get their own files.
///
/// Every function here takes an already-connected `AgentClient` and returns a plain `Codable`
/// result (or throws `LilpassError`) — no printing, no `--json` formatting, no exit-code handling.
/// That's the CLI target's job (it decides text vs. JSON and calls `exit(_:)`), which is what
/// makes this testable against an in-process `AgentServer` + `InMemoryVaultStore` the way
/// `AgentXPCEndToEndTests` already tests `AgentServer` itself.
public enum LilpassCommands {
  public static func status(client: AgentClient) async throws -> AgentStatus {
    do {
      return try await client.status()
    } catch {
      throw LilpassError.from(error)
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
      throw LilpassError.from(error)
    }
  }

  public static func search(client: AgentClient, query: String) async throws -> [ItemSummary] {
    do {
      let items = try await client.search(query)
      return items.map(ItemSummary.init)
    } catch {
      throw LilpassError.from(error)
    }
  }

  /// `lilpass get <item>` with no `--field`: the full, secret-including record.
  public static func getDetail(client: AgentClient, identifier: String) async throws -> ItemDetail {
    let item = try await resolveItem(identifier, client: client)
    return ItemDetail(item)
  }

  /// `lilpass get <item> --field <field>`: just that one field's value.
  public static func getField(client: AgentClient, identifier: String, field: ItemField) async throws -> FieldValue {
    let item = try await resolveItem(identifier, client: client)
    let value = try await SecretResolver.value(for: field, in: item, client: client)
    return FieldValue(item: item.title, field: field, value: value)
  }

  /// `lilpass read lilpass://<item>/<field>`.
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
      throw LilpassError.from(error)
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
      throw LilpassError.from(error)
    }
  }

  /// `lilpass add`: creates a new item. Requires agent write access on top of read access — see
  /// `AgentError.agentWriteAccessDisabled` (851-2433) — and is always denied for a plain `lilpass`
  /// invocation while that toggle is off, regardless of `--generate` vs. a piped-in `--password`.
  ///
  /// Returns an ``ItemSummary`` rather than the full item: like `list`/`search`, `add`/`edit`/`rm`
  /// are not among 851-2430's secret-revealing commands, even for a password the caller itself just
  /// supplied — a consistent rule is simpler to reason about than "except when you just typed it
  /// yourself", and the caller already has the plaintext they passed in anyway.
  public static func add(
    client: AgentClient,
    title: String,
    usernames: [String],
    password: String,
    websites: [String],
    notes: String,
    group: String?
  ) async throws -> ItemSummary {
    let parsedWebsites = try websites.map(parseWebsite)
    let item = PasswordItem(
      title: title,
      usernames: usernames,
      password: password,
      websites: parsedWebsites,
      notes: notes,
      group: group
    )
    do {
      let created = try await client.create(item)
      return ItemSummary(created)
    } catch {
      throw LilpassError.from(error)
    }
  }

  /// `lilpass edit <item>`: a partial update — every parameter left `nil` (or, for the array
  /// parameters, empty) leaves that field unchanged on the existing item. There is deliberately no
  /// way to clear ``PasswordItem/usernames``, ``PasswordItem/websites``, or
  /// ``PasswordItem/group`` back to empty/`nil` through `edit` today (only to replace them with a
  /// new non-empty value) — a real gap, but one `lilpass rm` + `lilpass add` already works around, and
  /// not one this ticket's `--field value` shape was asked to close.
  public static func edit(
    client: AgentClient,
    identifier: String,
    title: String?,
    usernames: [String],
    password: String?,
    websites: [String],
    notes: String?,
    group: String?
  ) async throws -> ItemSummary {
    var item = try await resolveItem(identifier, client: client)
    if let title { item.title = title }
    if !usernames.isEmpty { item.usernames = usernames }
    if let password { item.password = password }
    if !websites.isEmpty { item.websites = try websites.map(parseWebsite) }
    if let notes { item.notes = notes }
    if let group { item.group = group }
    item.modifiedAt = Date()
    do {
      let updated = try await client.update(item)
      return ItemSummary(updated)
    } catch {
      throw LilpassError.from(error)
    }
  }

  /// `lilpass rm <item>`: soft-deletes (moves to Recently Deleted) — see `AgentServer.vaultResponse`'s
  /// `.deleteItem` case — there is no permanent-delete request an agent caller (or this command)
  /// can reach. Returns the resolved item's ``ItemSummary`` (as it was immediately before deletion)
  /// so the caller can confirm what was removed.
  @discardableResult
  public static func remove(client: AgentClient, identifier: String) async throws -> ItemSummary {
    let item = try await resolveItem(identifier, client: client)
    do {
      try await client.delete(.id(item.id))
      return ItemSummary(item)
    } catch {
      throw LilpassError.from(error)
    }
  }

  /// Normalizes a `--website` argument the same way CSV import does (``ImportedCredential``):
  /// a bare `"example.com"` gets an `https://` scheme, and anything that still doesn't parse into a
  /// `URL` with a host is rejected rather than silently dropped — unlike import, a single bad
  /// `--website` on an explicit `add`/`edit` invocation should fail loudly, not disappear.
  private static func parseWebsite(_ string: String) throws -> URL {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let url = URL(string: withScheme), let host = url.host, !host.isEmpty else {
      throw LilpassError(exitCode: .usage, message: "\"\(string)\" isn't a valid website")
    }
    return url
  }

  /// Shared by every command that needs to resolve exactly one item: fetches the full list once
  /// and resolves `identifier` against it with `ItemResolver`. `LilpassRun` and `LilpassInject` call
  /// this directly for each `lilpass://` reference they need to resolve.
  public static func resolveItem(_ identifier: String, client: AgentClient) async throws -> PasswordItem {
    let items: [PasswordItem]
    do {
      items = try await client.list()
    } catch {
      throw LilpassError.from(error)
    }
    return try ItemResolver.resolve(identifier, in: items)
  }

  private static func filtered(_ items: [PasswordItem], byCategory category: String?) -> [PasswordItem] {
    guard let category else { return items }
    let normalized = category.lowercased()
    return items.filter { ($0.group ?? "").lowercased() == normalized }
  }
}
