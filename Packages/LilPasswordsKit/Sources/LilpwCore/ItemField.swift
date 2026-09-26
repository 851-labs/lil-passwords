import Foundation
import LilPasswordsKit

/// A single field on a ``PasswordItem`` that `lilpw get --field`, `lilpw read`, `lilpw run --env`,
/// and `lilpw inject` can extract.
///
/// `String`-backed (rather than, say, a raw `KeyPath`) so it round-trips through `--field <value>`,
/// a `lilpw://` secret reference's last path component, and `--json` output identically.
public enum ItemField: String, CaseIterable, Sendable, Equatable, Codable {
  case password
  case username
  case totp
  case notes
  case website
}

/// Reads `field` off `item`, or asks `client` for a fresh TOTP code, and returns it as a plain
/// string ready to print, inject into a template, or set as an environment variable.
///
/// This is the one place that actually touches a secret field's value — `ItemSummary` (used by
/// `list`/`search`) deliberately has no path to this function, which is what keeps secrets out of
/// those commands' output.
public enum SecretResolver {
  public static func value(for field: ItemField, in item: PasswordItem, client: AgentClient) async throws -> String {
    switch field {
    case .password:
      return item.password

    case .username:
      guard let username = item.usernames.first else {
        throw LilpwError(exitCode: .notFound, message: "\"\(item.title)\" has no username")
      }
      return username

    case .notes:
      return item.notes

    case .website:
      guard let website = item.websites.first else {
        throw LilpwError(exitCode: .notFound, message: "\"\(item.title)\" has no website")
      }
      return website.absoluteString

    case .totp:
      do {
        let result = try await client.totpCode(.id(item.id))
        return result.code
      } catch {
        throw LilpwError.from(error)
      }
    }
  }
}
