import Foundation

/// The one JSON encoding lilpass ever uses for machine-readable output: sorted keys (stable, diffable
/// output) and ISO-8601 dates. Shared by the CLI's `--json` flag (`Output.print`) and the MCP
/// server's tool results (`LilpassMCP`) so both surfaces serialize the exact same `Codable` values
/// (`ItemSummary`, `ItemDetail`, `FieldValue`, ...) identically.
public enum LilpassJSON {
  public static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  /// Encodes `value` as a UTF-8 JSON string, or `nil` if encoding fails.
  public static func string<T: Encodable>(_ value: T) -> String? {
    guard let data = try? encoder.encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
