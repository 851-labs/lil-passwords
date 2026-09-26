import Foundation
import LilPasswordsKit

/// The non-secret view of a ``PasswordItem`` `lilpw list` and `lilpw search` print.
///
/// Deliberately omits `password` and `notes` (either can hold a secret) and the live TOTP code
/// (which needs a fresh ``AgentClient/totpCode(_:)`` call, not just the item) — 851-2430 requires
/// that secrets only ever reach stdout from `get`/`read`/`totp`, and `list`/`search` are not those
/// commands.
public struct ItemSummary: Codable, Sendable, Equatable {
  public let id: UUID
  public let title: String
  public let usernames: [String]
  public let websites: [String]
  public let group: String?
  public let hasTOTP: Bool

  public init(_ item: PasswordItem) {
    id = item.id
    title = item.title
    usernames = item.usernames
    websites = item.websites.map(\.absoluteString)
    group = item.group
    hasTOTP = item.totpURI != nil
  }
}

/// The full, secret-including view of a single item `lilpw get <item>` prints when called without
/// `--field`. Unlike ``ItemSummary``, this does include `password` and `notes` — `get` (with or
/// without `--field`) is one of 851-2430's explicit secret-revealing commands.
///
/// Still omits the live TOTP code for the same reason `ItemSummary` does (it needs a fresh
/// `AgentClient` call); `hasTOTP` tells a caller whether `lilpw totp <item>` will work.
public struct ItemDetail: Codable, Sendable, Equatable {
  public let id: UUID
  public let title: String
  public let usernames: [String]
  public let password: String
  public let websites: [String]
  public let notes: String
  public let group: String?
  public let hasTOTP: Bool

  public init(_ item: PasswordItem) {
    id = item.id
    title = item.title
    usernames = item.usernames
    password = item.password
    websites = item.websites.map(\.absoluteString)
    notes = item.notes
    group = item.group
    hasTOTP = item.totpURI != nil
  }
}

/// A single resolved field's value, e.g. the payload of `lilpw get --field password` or
/// `lilpw read`.
public struct FieldValue: Codable, Sendable, Equatable {
  public let item: String
  public let field: ItemField
  public let value: String

  public init(item: String, field: ItemField, value: String) {
    self.item = item
    self.field = field
    self.value = value
  }
}
