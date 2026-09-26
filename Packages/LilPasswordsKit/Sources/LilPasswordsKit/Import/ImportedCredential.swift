/// A single credential produced by parsing a row of an imported CSV file.
///
/// This is a small, standalone type rather than the eventual vault item model (`PasswordItem`,
/// tracked separately) — it exists so the import engine can be built and tested independently.
/// Callers are expected to adapt values of this type into the vault's item model once it lands.
public struct ImportedCredential: Equatable, Sendable {
  /// The item's display title, e.g. the site or service name.
  public var title: String

  /// The account username or email. May be empty if the source row had none.
  public var username: String

  /// The account password. May be empty if the source row had none.
  public var password: String

  /// Every URL associated with the item, in the order the source listed them.
  public var urls: [String]

  /// Free-text notes, or `nil` if the source row had none.
  public var notes: String?

  /// A `otpauth://` URI or raw TOTP secret carried by the source row, or `nil` if none.
  public var otpAuth: String?

  public init(
    title: String,
    username: String,
    password: String,
    urls: [String] = [],
    notes: String? = nil,
    otpAuth: String? = nil
  ) {
    self.title = title
    self.username = username
    self.password = password
    self.urls = urls
    self.notes = notes
    self.otpAuth = otpAuth
  }
}
