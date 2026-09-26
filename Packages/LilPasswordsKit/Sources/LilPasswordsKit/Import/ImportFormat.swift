import Foundation

/// The CSV export formats the importer can recognize and parse.
public enum ImportFormat: String, Equatable, Sendable, CaseIterable {
  /// Apple Passwords and Safari both export `Title,URL,Username,Password,Notes,OTPAuth`.
  case applePasswords

  /// Chrome / Google Password Manager: `name,url,username,password,note`.
  case chrome

  /// 1Password's login CSV export: `Title,Url,Username,Password,Notes,OTPAuth`.
  case onePassword

  /// Bitwarden's vault CSV export, individual-vault layout: `folder,favorite,type,name,notes,
  /// fields,reprompt,login_uri,login_username,login_password,login_totp`.
  case bitwarden

  /// A human-readable name for UI and logging.
  public var displayName: String {
    switch self {
    case .applePasswords: return "Apple Passwords / Safari"
    case .chrome: return "Chrome"
    case .onePassword: return "1Password"
    case .bitwarden: return "Bitwarden"
    }
  }
}

/// Detects an ``ImportFormat`` from a CSV header row.
///
/// Detection looks for each format's distinguishing column names as a subset of the header row,
/// so exports with extra or reordered columns (e.g. Bitwarden's `favorite`/`reprompt`) still
/// match. Apple/Safari and 1Password headers are identical apart from `URL` vs. `Url`'s casing,
/// which is exactly how the two products' exports differ.
enum ImportFormatDetector {
  private static let bitwardenSignature: Set<String> = [
    "type", "name", "login_uri", "login_username", "login_password",
  ]
  private static let applePasswordsSignature: Set<String> = ["Title", "URL", "Username", "Password"]
  private static let onePasswordSignature: Set<String> = ["Title", "Url", "Username", "Password"]
  private static let chromeSignature: Set<String> = ["name", "url", "username", "password"]

  static func detect(headers: [String]) -> ImportFormat? {
    let columns = Set(headers.map { $0.trimmingCharacters(in: .whitespaces) })

    if columns.isSuperset(of: bitwardenSignature) {
      return .bitwarden
    }
    if columns.isSuperset(of: applePasswordsSignature) {
      return .applePasswords
    }
    if columns.isSuperset(of: onePasswordSignature) {
      return .onePassword
    }
    if columns.isSuperset(of: chromeSignature) {
      return .chrome
    }
    return nil
  }
}
