import Foundation
import LilPasswordsKit
import LilpassCore

/// Reads a secret piped into `lilpass` on stdin — `add --password -` and `edit --password -`'s only
/// supported way to supply a literal password, so it never appears as a command-line argument
/// where `ps`/shell history/process-listing tools on the same machine could read it back.
enum StandardInput {
  /// Reads all of stdin, trims exactly one trailing line ending (if present, since most ways of
  /// piping a password in add one), and rejects an empty result — an empty password read as "no
  /// password" would be a confusing way to fail this far into parsing `add`/`edit`'s arguments.
  static func readPassword() throws -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard var text = String(data: data, encoding: .utf8) else {
      throw LilpassError(exitCode: .usage, message: "couldn't read a password from stdin as UTF-8 text")
    }
    if text.hasSuffix("\n") { text.removeLast() }
    if text.hasSuffix("\r") { text.removeLast() }
    guard !text.isEmpty else {
      throw LilpassError(
        exitCode: .usage,
        message: "expected a password piped into stdin (got none) — e.g. `echo -n hunter2 | "
          + "\(LilPasswordsKit.cliName) add --password - ...`, or pass --generate instead"
      )
    }
    return text
  }
}
