/// A vault entry to compare an import against, for dedupe/merge planning.
///
/// Standalone stand-in for the eventual vault item model (`PasswordItem`, tracked separately) —
/// callers currently in the vault-core milestone can project their real items into this shape.
public struct ExistingCredential: Equatable, Sendable, Identifiable {
  /// A stable identifier for the existing vault item.
  public var id: String

  public var title: String
  public var username: String
  public var password: String
  public var urls: [String]
  public var notes: String?
  public var otpAuth: String?

  public init(
    id: String,
    title: String,
    username: String,
    password: String,
    urls: [String] = [],
    notes: String? = nil,
    otpAuth: String? = nil
  ) {
    self.id = id
    self.title = title
    self.username = username
    self.password = password
    self.urls = urls
    self.notes = notes
    self.otpAuth = otpAuth
  }
}
