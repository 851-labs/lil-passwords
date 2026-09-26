import Foundation

/// Parses a password manager's CSV export into ``ImportedCredential`` values.
///
/// Usage is a single call: ``importCSV(_:)-(String)`` (or the `Data` overload) parses the raw
/// text, detects which of the supported formats produced it from its header row, and maps every
/// data row into an ``ImportedCredential``. Rows that carry no usable data (e.g. a Bitwarden
/// secure note rather than a login) are counted in ``Result/skippedRowCount`` rather than
/// reported as an error.
public enum CSVImporter {
  /// The result of a successful import.
  public struct Result: Equatable, Sendable {
    /// The detected source format.
    public var format: ImportFormat

    /// Every row that mapped to a usable credential.
    public var credentials: [ImportedCredential]

    /// Rows that were recognized as belonging to the format but carried no importable
    /// credential (e.g. a Bitwarden secure note, or a fully blank row).
    public var skippedRowCount: Int
  }

  /// An error that stops an import before any credentials are produced.
  public enum ImportError: Error, Equatable, Sendable {
    /// The CSV had no rows at all (or only a blank line).
    case emptyFile
    /// The header row didn't match any known format.
    case unrecognizedFormat(headers: [String])
  }

  /// Parses CSV text and maps it into credentials.
  public static func importCSV(_ text: String) throws -> Result {
    let rows = try CSVParser.parse(text)
    return try importRows(rows)
  }

  /// Parses CSV bytes and maps them into credentials.
  public static func importCSV(data: Data) throws -> Result {
    let rows = try CSVParser.parse(data: data)
    return try importRows(rows)
  }

  /// Detects the format of a CSV file from its header row alone, without mapping any rows.
  public static func detectFormat(_ text: String) throws -> ImportFormat? {
    let rows = try CSVParser.parse(text)
    guard let headerRow = firstNonBlankRow(in: rows) else { return nil }
    return ImportFormatDetector.detect(headers: headerRow)
  }

  private static func importRows(_ rows: [[String]]) throws -> Result {
    guard let headerRow = firstNonBlankRow(in: rows) else {
      throw ImportError.emptyFile
    }
    guard let format = ImportFormatDetector.detect(headers: headerRow) else {
      throw ImportError.unrecognizedFormat(headers: headerRow)
    }

    var credentials: [ImportedCredential] = []
    var skippedRowCount = 0

    for row in rows.dropFirst() where !isBlank(row) {
      let fields = fieldMap(headerRow: headerRow, row: row)
      if let credential = mapRow(fields, format: format) {
        credentials.append(credential)
      } else {
        skippedRowCount += 1
      }
    }

    return Result(format: format, credentials: credentials, skippedRowCount: skippedRowCount)
  }

  private static func firstNonBlankRow(in rows: [[String]]) -> [String]? {
    rows.first { !isBlank($0) }
  }

  private static func isBlank(_ row: [String]) -> Bool {
    row.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
  }

  private static func fieldMap(headerRow: [String], row: [String]) -> [String: String] {
    var fields: [String: String] = [:]
    for (index, key) in headerRow.enumerated() {
      fields[key] = index < row.count ? row[index] : ""
    }
    return fields
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func mapRow(_ fields: [String: String], format: ImportFormat) -> ImportedCredential? {
    switch format {
    case .applePasswords:
      return mapApplePasswordsRow(fields)
    case .onePassword:
      return mapOnePasswordRow(fields)
    case .chrome:
      return mapChromeRow(fields)
    case .bitwarden:
      return mapBitwardenRow(fields)
    }
  }

  private static func mapApplePasswordsRow(_ fields: [String: String]) -> ImportedCredential? {
    let username = fields["Username"] ?? ""
    let password = fields["Password"] ?? ""
    let url = nonEmpty(fields["URL"])
    guard !(username.isEmpty && password.isEmpty && url == nil) else { return nil }

    return ImportedCredential(
      title: nonEmpty(fields["Title"]) ?? url ?? "Untitled",
      username: username,
      password: password,
      urls: url.map { [$0] } ?? [],
      notes: nonEmpty(fields["Notes"]),
      otpAuth: nonEmpty(fields["OTPAuth"])
    )
  }

  private static func mapOnePasswordRow(_ fields: [String: String]) -> ImportedCredential? {
    let username = fields["Username"] ?? ""
    let password = fields["Password"] ?? ""
    let url = nonEmpty(fields["Url"])
    guard !(username.isEmpty && password.isEmpty && url == nil) else { return nil }

    return ImportedCredential(
      title: nonEmpty(fields["Title"]) ?? url ?? "Untitled",
      username: username,
      password: password,
      urls: url.map { [$0] } ?? [],
      notes: nonEmpty(fields["Notes"]),
      otpAuth: nonEmpty(fields["OTPAuth"])
    )
  }

  private static func mapChromeRow(_ fields: [String: String]) -> ImportedCredential? {
    let username = fields["username"] ?? ""
    let password = fields["password"] ?? ""
    let url = nonEmpty(fields["url"])
    guard !(username.isEmpty && password.isEmpty && url == nil) else { return nil }

    return ImportedCredential(
      title: nonEmpty(fields["name"]) ?? url ?? "Untitled",
      username: username,
      password: password,
      urls: url.map { [$0] } ?? [],
      notes: nonEmpty(fields["note"]),
      otpAuth: nil
    )
  }

  private static func mapBitwardenRow(_ fields: [String: String]) -> ImportedCredential? {
    // Bitwarden's CSV mixes login and secure-note items in one file; only logins carry
    // credential data, so anything else is a skip rather than a mapping failure.
    guard (fields["type"] ?? "").lowercased() == "login" else { return nil }

    let username = fields["login_username"] ?? ""
    let password = fields["login_password"] ?? ""
    let urls =
      (fields["login_uri"] ?? "")
      .split(separator: ",", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard !(username.isEmpty && password.isEmpty && urls.isEmpty) else { return nil }

    return ImportedCredential(
      title: nonEmpty(fields["name"]) ?? urls.first ?? "Untitled",
      username: username,
      password: password,
      urls: urls,
      notes: nonEmpty(fields["notes"]),
      otpAuth: nonEmpty(fields["login_totp"])
    )
  }
}
