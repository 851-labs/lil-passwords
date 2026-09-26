import Foundation

/// A `lilpass://<item>/<field>` secret reference, the same shape `lilpass read`, `lilpass run --env`, and
/// `lilpass inject`'s `{{ lilpass://... }}` template placeholders all share — modeled on `op read`'s
/// `op://vault/item/field` references.
///
/// `item` is whatever ``ItemResolver`` accepts (an id, exact title, or website domain). Because it
/// travels as a URL host, an identifier containing characters a URL host can't hold (spaces,
/// non-ASCII) must be percent-encoded by whoever writes the reference — `get`/`totp`/`search`'s
/// plain string arguments have no such restriction.
public struct SecretReference: Sendable, Equatable {
  public static let scheme = "lilpass"

  public let item: String
  public let field: ItemField

  public init(item: String, field: ItemField) {
    self.item = item
    self.field = field
  }

  /// Parses `string`, or returns `nil` if it isn't a well-formed `lilpass://<item>/<field>`
  /// reference (wrong scheme, missing item, missing/unrecognized field, or extra path segments).
  public init?(string: String) {
    guard let components = URLComponents(string: string), components.scheme == SecretReference.scheme else {
      return nil
    }
    guard let host = components.host, !host.isEmpty else { return nil }

    let pathSegments = components.path.split(separator: "/", omittingEmptySubsequences: true)
    guard pathSegments.count == 1, let field = ItemField(rawValue: pathSegments[0].lowercased()) else {
      return nil
    }

    self.item = host.removingPercentEncoding ?? host
    self.field = field
  }
}
