import Foundation

/// A single vault entry: a login, its metadata, and its optional TOTP secret.
///
/// `PasswordItem` is the plaintext shape a user (or an agent) actually works with. It never
/// appears on disk or in `VaultStore` on its own — `RecordCodec` seals it into a `VaultRecord`
/// before it's persisted, so every field here, including `title` and `websites`, ends up inside
/// ciphertext rather than in a plaintext database column. See `docs/adr/0002-crypto.md` and
/// `VaultRecord`'s documentation for why the envelope around this type stays minimal.
public struct PasswordItem: Codable, Sendable, Hashable {
  /// A stable, globally unique identifier, generated once when the item is created and never
  /// reused. Uses UUID version 7 (`UUID.v7()`) so ids sort roughly by creation time.
  public var id: UUID

  /// The item's display title, e.g. the site or service name.
  public var title: String

  /// Usernames or account identifiers associated with this item. Most items have exactly one;
  /// an array allows for logins with multiple valid usernames (e.g. a username and an email).
  public var usernames: [String]

  /// The account password.
  public var password: String

  /// Every website associated with this item, in display order. Represented as `URL` (rather
  /// than a raw `String`) so a malformed value is caught at construction time instead of at
  /// render time — see `PasswordItemSchema` for how looser, string-based data (e.g. from CSV
  /// import) is expected to be validated on the way in.
  public var websites: [URL]

  /// Free-text notes.
  public var notes: String

  /// The `otpauth://` URI for this item's two-factor code, or `nil` if it has none. Stored as
  /// the raw URI string (rather than a parsed `OTPAuthURI`/`TOTP`) so an item with a URI this
  /// build doesn't fully understand still round-trips losslessly; use ``totp`` to get a usable
  /// generator out of it.
  public var totpURI: String?

  /// The name of the group (folder/category) this item belongs to, or `nil` if ungrouped.
  public var group: String?

  /// When this item was first created.
  public var createdAt: Date

  /// When this item's fields were last changed.
  public var modifiedAt: Date

  /// When this item's password was last used to fill or copy, or `nil` if never used.
  public var lastUsedAt: Date?

  /// When the user moved this item to "Recently Deleted", or `nil` if it isn't deleted.
  ///
  /// This is the user-facing, in-place soft delete (the item is still fully present in this
  /// `PasswordItem`, just flagged as trashed) and is distinct from `VaultRecord.deleted`, which
  /// is the sync-layer tombstone marking that a row's content has been purged entirely. An item
  /// can have `deletedAt` set while its `VaultRecord.deleted` is still `false` (it's sitting in
  /// Recently Deleted, still fully recoverable); `VaultRecord.deleted` only flips once the
  /// retention window ends and the content itself is dropped.
  public var deletedAt: Date?

  /// Whether this item's security warning (e.g. "this password was found in a data breach" or
  /// "this password is reused elsewhere") has been dismissed by the user for this specific item.
  public var securityWarningHidden: Bool

  public init(
    id: UUID = .v7(),
    title: String,
    usernames: [String] = [],
    password: String = "",
    websites: [URL] = [],
    notes: String = "",
    totpURI: String? = nil,
    group: String? = nil,
    createdAt: Date = Date(),
    modifiedAt: Date = Date(),
    lastUsedAt: Date? = nil,
    deletedAt: Date? = nil,
    securityWarningHidden: Bool = false
  ) {
    self.id = id
    self.title = title
    self.usernames = usernames
    self.password = password
    self.websites = websites
    self.notes = notes
    self.totpURI = totpURI
    self.group = group
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt
    self.lastUsedAt = lastUsedAt
    self.deletedAt = deletedAt
    self.securityWarningHidden = securityWarningHidden
  }

  /// A ready-to-use TOTP generator parsed from ``totpURI``, or `nil` if there is no URI or it
  /// fails to parse (e.g. a URI this build doesn't understand). Parse failures are silent here
  /// by design — a corrupt or unrecognized `totpURI` shouldn't prevent the rest of the item
  /// (password, notes, etc.) from being usable.
  public var totp: TOTP? {
    guard let totpURI, let url = URL(string: totpURI) else { return nil }
    return try? OTPAuthURI(url: url).totp
  }
}
