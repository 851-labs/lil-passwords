import Foundation

extension PasswordItem {
  /// The well-known "change your password here" URL for this item's primary website, per the
  /// `changePassword` URL specification (RFC 8615 `.well-known`) Apple Passwords' "Change
  /// Password on Website" button opens: `https://<host>/.well-known/change-password`.
  ///
  /// Uses ``websites``' first entry only — Apple Passwords' own button does the same when an
  /// item has more than one website — and returns `nil` if the item has no website to derive a
  /// host from.
  public var changePasswordURL: URL? {
    guard let host = websites.first?.host, !host.isEmpty else { return nil }
    return URL(string: "https://\(host)/.well-known/change-password")
  }
}
