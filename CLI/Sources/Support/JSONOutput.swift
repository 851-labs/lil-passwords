import ArgumentParser
import Foundation
import LilPasswordsKit
import LilpwCore

/// The `--json` flag every `lilpw` subcommand mixes in via `@OptionGroup`, per 851-2430's "every
/// command supports `--json`" requirement.
struct JSONOutputOptions: ParsableArguments {
  @Flag(name: .long, help: "Output machine-readable JSON instead of plain text.")
  var json = false

  init() {}
}

/// Formats a `LilpwCore` command's result as either `--json` or a command-specific plain-text
/// rendering. Kept here (rather than in `LilpwCore`) because formatting is presentation, not
/// logic — `LilpwCore` only ever returns plain `Codable` values.
enum Output {
  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  /// Prints `value` as JSON if `asJSON` is `true`; otherwise calls `text` to print a
  /// command-specific human-readable rendering. `text` never runs when `asJSON` is `true`.
  static func print<T: Encodable>(_ value: T, asJSON: Bool, text: (T) -> Void) {
    guard asJSON else {
      text(value)
      return
    }
    guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) else {
      FileHandle.standardError.write(Data("\(LilPasswordsKit.cliName): failed to encode JSON output\n".utf8))
      exit(LilpwExitCode.generic.rawValue)
    }
    Swift.print(string)
  }
}
