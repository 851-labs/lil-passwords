import Foundation

/// Adapters between the CSV import/export engine's standalone types (``ImportedCredential``,
/// ``ExistingCredential``) and the vault's real item model, ``PasswordItem``.
///
/// ``ImportedCredential`` and ``ExistingCredential`` predate `PasswordItem` in this codebase (see
/// their own doc comments) so the import engine (851-2409) could be built and tested without
/// waiting on the vault-core milestone. Now that both exist, this is the one place a caller — the
/// import UI (851-2410) — needs to convert between the two shapes.
extension ImportedCredential {
  /// Builds a fresh `PasswordItem` from this imported row, ready to hand to
  /// `VaultStoring.create(_:)`.
  ///
  /// - `urls` become `PasswordItem.websites`: normalized the same way ``ImportMergePlanner``
  ///   compares them (a bare `"example.com"` gets an `https://` scheme rather than becoming a
  ///   `URL` with no host), and anything that still won't parse into a URL with a host is dropped
  ///   rather than failing the whole import.
  /// - `otpAuth` becomes `PasswordItem.totpURI`. An `otpauth://` URI is used as-is; a raw base32
  ///   secret — how some sources (e.g. Bitwarden's `login_totp` column, in the wild) actually
  ///   encode it — is wrapped into a proper `otpauth://` URI first, since that's the only shape
  ///   `PasswordItem.totp` knows how to parse.
  public func asPasswordItem(
    id: UUID = .v7(),
    createdAt: Date = Date(),
    modifiedAt: Date? = nil
  ) -> PasswordItem {
    PasswordItem(
      id: id,
      title: title,
      usernames: username.isEmpty ? [] : [username],
      password: password,
      websites: urls.compactMap(Self.website(from:)),
      notes: notes ?? "",
      totpURI: Self.totpURI(fromOTPAuth: otpAuth, accountName: username.isEmpty ? title : username),
      createdAt: createdAt,
      modifiedAt: modifiedAt ?? createdAt
    )
  }

  /// Returns a copy of `item` with every content field replaced by this imported row's values,
  /// keeping `item`'s identity (`id`, `createdAt`) intact. Used for a "Replace" conflict
  /// resolution during import: the existing vault item stays the same item, just with the
  /// imported values written over its old ones.
  public func replacing(_ item: PasswordItem) -> PasswordItem {
    var updated = item
    updated.title = title
    updated.usernames = username.isEmpty ? [] : [username]
    updated.password = password
    updated.websites = urls.compactMap(Self.website(from:))
    updated.notes = notes ?? ""
    updated.totpURI = Self.totpURI(fromOTPAuth: otpAuth, accountName: username.isEmpty ? title : username)
    updated.modifiedAt = Date()
    return updated
  }

  fileprivate static func website(from urlString: String) -> URL? {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let url = URL(string: withScheme), let host = url.host, !host.isEmpty else { return nil }
    return url
  }

  /// - Parameter accountName: Used as the label if `otpAuth` turns out to be a raw secret rather
  ///   than a full URI, so the resulting `otpauth://` URI still identifies whose code it is.
  fileprivate static func totpURI(fromOTPAuth otpAuth: String?, accountName: String) -> String? {
    guard let otpAuth else { return nil }
    let trimmed = otpAuth.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let url = URL(string: trimmed), url.scheme?.lowercased() == "otpauth" {
      return trimmed
    }

    guard let secret = Base32.decode(trimmed), !secret.isEmpty, let totp = try? TOTP(secret: secret) else {
      return nil
    }
    return OTPAuthURI(accountName: accountName, totp: totp).url.absoluteString
  }
}

extension PasswordItem {
  /// Projects this vault item into ``ExistingCredential``, the shape ``ImportMergePlanner``
  /// compares an import against. `id` is `PasswordItem.id.uuidString`, so a caller that gets a
  /// matched `ExistingCredential` back from the planner can map it straight back to the
  /// `PasswordItem` to update.
  public func asExistingCredential() -> ExistingCredential {
    ExistingCredential(
      id: id.uuidString,
      title: title,
      username: usernames.first ?? "",
      password: password,
      urls: websites.map(\.absoluteString),
      notes: notes.isEmpty ? nil : notes,
      otpAuth: totpURI
    )
  }
}
