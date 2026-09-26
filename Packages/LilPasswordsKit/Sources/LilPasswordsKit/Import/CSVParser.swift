import Foundation

/// An error thrown while parsing raw CSV text or bytes.
public enum CSVParsingError: Error, Equatable, Sendable {
  /// The input ended while a quoted field was still open (an unmatched `"`).
  case unterminatedQuotedField
  /// The input bytes could not be decoded as UTF-8 text.
  case invalidEncoding
}

/// A minimal RFC 4180 CSV parser.
///
/// Supports the parts of the spec real-world exports rely on: comma-separated fields, `"`-quoted
/// fields (with `""` as an escaped quote and embedded commas or newlines inside them), and both
/// `\r\n` and bare `\n` line endings. A leading UTF-8 byte-order mark is stripped automatically.
///
/// This type only tokenizes rows and fields; it has no knowledge of any particular password
/// manager's export format. See ``CSVImporter`` for format detection and row mapping.
public enum CSVParser {
  /// Parses CSV text into rows of fields.
  ///
  /// The header row (if any) is included as the first row; callers that expect a header are
  /// responsible for peeling it off. Fully blank trailing input produces no trailing empty row.
  ///
  /// - Throws: ``CSVParsingError/unterminatedQuotedField`` if a quoted field is never closed.
  public static func parse(_ text: String) throws -> [[String]] {
    var input = Substring(text)
    if input.unicodeScalars.first == "\u{FEFF}" {
      input.unicodeScalars.removeFirst()
    }

    // Walk Unicode scalars rather than `Character`s: Swift's grapheme-cluster segmentation
    // treats a "\r\n" pair as a single `Character`, which would make `\r` and `\n` unmatchable
    // as individual cases below.
    let scalars = Array(input.unicodeScalars)
    let count = scalars.count

    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var inQuotes = false

    func endField() {
      row.append(field)
      field = ""
    }
    func endRow() {
      endField()
      rows.append(row)
      row = []
    }

    var i = 0
    while i < count {
      let c = scalars[i]
      if inQuotes {
        if c == "\"" {
          if i + 1 < count, scalars[i + 1] == "\"" {
            field.unicodeScalars.append("\"")
            i += 2
          } else {
            inQuotes = false
            i += 1
          }
        } else {
          field.unicodeScalars.append(c)
          i += 1
        }
        continue
      }

      switch c {
      case "\"":
        inQuotes = true
        i += 1
      case ",":
        endField()
        i += 1
      case "\r":
        if i + 1 < count, scalars[i + 1] == "\n" {
          i += 1
        }
        endRow()
        i += 1
      case "\n":
        endRow()
        i += 1
      default:
        field.unicodeScalars.append(c)
        i += 1
      }
    }

    guard !inQuotes else {
      throw CSVParsingError.unterminatedQuotedField
    }

    if !field.isEmpty || !row.isEmpty {
      endRow()
    }

    return rows
  }

  /// Parses CSV bytes, stripping a UTF-8 byte-order mark before decoding.
  public static func parse(data: Data) throws -> [[String]] {
    var bytes = data
    let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    if bytes.count >= 3, Array(bytes.prefix(3)) == utf8BOM {
      bytes.removeFirst(3)
    }
    guard let text = String(data: bytes, encoding: .utf8) else {
      throw CSVParsingError.invalidEncoding
    }
    return try parse(text)
  }
}
