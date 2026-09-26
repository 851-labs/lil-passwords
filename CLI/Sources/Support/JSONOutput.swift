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
  /// Prints `value` as JSON if `asJSON` is `true`; otherwise calls `text` to print a
  /// command-specific human-readable rendering. `text` never runs when `asJSON` is `true`.
  ///
  /// Uses `LilpwCore.LilpwJSON`'s shared encoder — the same one `LilpwMCP`'s tool results use —
  /// so `--json` output and MCP tool output serialize identically.
  static func print<T: Encodable>(_ value: T, asJSON: Bool, text: (T) -> Void) {
    guard asJSON else {
      text(value)
      return
    }
    guard let string = LilpwJSON.string(value) else {
      FileHandle.standardError.write(Data("\(LilPasswordsKit.cliName): failed to encode JSON output\n".utf8))
      exit(LilpwExitCode.generic.rawValue)
    }
    Swift.print(string)
  }
}
