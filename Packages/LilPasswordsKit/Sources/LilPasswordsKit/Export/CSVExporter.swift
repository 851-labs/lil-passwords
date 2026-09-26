import Foundation

/// Writes vault items out in the Apple Passwords CSV export format
/// (`Title,URL,Username,Password,Notes,OTPAuth`) — the same header `ImportFormatDetector`
/// recognizes as ``ImportFormat/applePasswords``.
///
/// This is deliberately the only format `CSVExporter` writes. Inventing a richer, app-specific
/// format would produce a file only this app could read back; matching some *other* app's format
/// (1Password, Bitwarden, ...) isn't needed either, since Apple Passwords' shape already round-trips
/// losslessly through this app's own `CSVImporter` for everything it can represent. See
/// `CSVExporterTests.roundTripsThroughImporter`.
public enum CSVExporter {
  private static let header = ["Title", "URL", "Username", "Password", "Notes", "OTPAuth"]

  /// Renders `items` as Apple Passwords CSV text.
  ///
  /// - Deleted items (`item.deletedAt != nil`) are always excluded — exporting is for a user's
  ///   active passwords, not their "Recently Deleted" trash.
  /// - Only the first of `item.websites` / `item.usernames` is written, since the Apple Passwords
  ///   format has a single `URL`/`Username` column per row. An item with more than one of either
  ///   loses the extras on export; this matches the real Apple Passwords app's own export, which
  ///   has the same single-column shape.
  /// - Rows end with `\r\n`, matching the fixture files real exporters (including Apple's)
  ///   produce; `CSVParser` accepts either line ending regardless.
  public static func csvText(for items: [PasswordItem]) -> String {
    var lines = [row(header)]
    for item in items where item.deletedAt == nil {
      lines.append(row(fields(for: item)))
    }
    return lines.map { $0 + "\r\n" }.joined()
  }

  /// Renders `items` as UTF-8 CSV bytes. See ``csvText(for:)``.
  public static func csvData(for items: [PasswordItem]) -> Data {
    Data(csvText(for: items).utf8)
  }

  /// Writes `items` as Apple Passwords CSV to `url`, creating (or replacing) the file with
  /// permissions restricted to the owner only (`0600`).
  ///
  /// This file is plaintext — every password and TOTP secret in the vault, unencrypted, sitting
  /// on disk — so it's deliberately never left group/world-readable, even for the brief window
  /// before the user deletes it. Any existing file at `url` is removed first, since
  /// `FileManager.createFile(atPath:contents:attributes:)` only applies `attributes` when it
  /// creates a new file, not when it overwrites an existing one.
  ///
  /// - Throws: `CocoaError` if the existing file can't be removed, or the new one can't be
  ///   created (e.g. an unwritable directory).
  public static func write(_ items: [PasswordItem], to url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }

    let created = FileManager.default.createFile(
      atPath: url.path,
      contents: csvData(for: items),
      attributes: [.posixPermissions: 0o600]
    )
    guard created else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
  }

  private static func fields(for item: PasswordItem) -> [String] {
    [
      item.title,
      item.websites.first?.absoluteString ?? "",
      item.usernames.first ?? "",
      item.password,
      item.notes,
      item.totpURI ?? "",
    ]
  }

  private static func row(_ fields: [String]) -> String {
    fields.map(quotedIfNeeded).joined(separator: ",")
  }

  /// Quotes a field per RFC 4180 if it contains a comma, quote, or newline, doubling any interior
  /// quotes. Matches exactly what `CSVParser` expects to unquote on the way back in.
  private static func quotedIfNeeded(_ field: String) -> String {
    guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
      return field
    }
    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}
