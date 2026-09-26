import ArgumentParser
import Foundation
import LilPasswordsKit
import LilpwCore

/// `lilpw`: command-line access to the vault, over XPC to `LilPasswordsAgent`. See
/// docs/adr/0001-storage-and-process-model.md for why every command here goes through
/// `AgentClient` rather than touching the vault or Keychain directly — `lilpw` is a bare Mach-O
/// with no bundle to hold a provisioning profile, so it structurally can't hold any entitlement
/// that would let it do so.
///
/// Argument parsing (this file and `Commands/`) is deliberately thin: every subcommand's actual
/// logic lives in `LilpwCore` (`LilpwCommands`, `LilpwRun`, `LilpwInject`), which is unit-tested
/// against an in-process `AgentServer` + `InMemoryVaultStore` without any of ArgumentParser
/// involved. This file's only jobs are turning parsed arguments into `LilpwCore` calls, formatting
/// results as text or `--json`, and mapping every failure to one of 851-2430's stable exit codes.
@main
struct Lilpw: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: LilPasswordsKit.cliName,
    abstract: "Command-line access to your lil passwords vault.",
    discussion: """
      Every command talks to LilPasswordsAgent over XPC — lilpw never reads the vault directly.
      Secrets only ever reach stdout from `get`, `read`, and `totp`; `run` and `inject` resolve
      secrets without printing them.
      """,
    subcommands: [
      StatusCommand.self,
      ListCommand.self,
      SearchCommand.self,
      GetCommand.self,
      ReadCommand.self,
      TotpCommand.self,
      GenerateCommand.self,
      RunCommand.self,
      InjectCommand.self,
    ]
  )

  /// A custom entry point rather than `AsyncParsableCommand`'s default `main()`.
  ///
  /// This mirrors that default implementation exactly (parse, run, catch-and-exit — see
  /// `AsyncParsableCommand.main(_:)`) except for the `catch` branch: 851-2430 specifies a stable
  /// 0–7 exit code scheme (``LilpwExitCode``) that doesn't match any of ArgumentParser's own
  /// defaults (`EX_USAGE` = 64 for a parse/validation failure, `EXIT_FAILURE` = 1 for an arbitrary
  /// thrown error), so every failure is routed through ``exitReportingError(_:)`` instead of
  /// `Lilpw.exit(withError:)`.
  static func main() async {
    do {
      var command = try await asyncParseAsRoot()
      if var asyncCommand = command as? AsyncParsableCommand {
        try await asyncCommand.run()
      } else {
        try command.run()
      }
    } catch {
      exitReportingError(error)
    }
  }

  /// Prints an appropriate message (if any) and exits with the right code, for anything a
  /// subcommand's `run()` or argument parsing itself can throw.
  private static func exitReportingError(_ error: Error) -> Never {
    // A `LilpwCore` command failure already carries its own stable exit code and a message that's
    // safe to print (never a secret value — see `LilpwError`'s documentation).
    if let lilpwError = error as? LilpwError {
      FileHandle.standardError.write(Data("\(LilPasswordsKit.cliName): \(lilpwError.message)\n".utf8))
      Foundation.exit(lilpwError.exitCode.rawValue)
    }

    // `RunCommand` throws a plain `ExitCode` to forward a child process's exact exit status —
    // never one of `LilpwExitCode`'s cases, and with nothing left to print (the child already
    // owns stdout/stderr; see `LilpwRun.run`'s documentation on why lilpw never intercepts it).
    if let exitCode = error as? ExitCode {
      Foundation.exit(exitCode.rawValue)
    }

    // Anything else came from ArgumentParser itself: a `--help`/`--version`/completion request
    // (which should print to stdout and exit 0), or a genuine parse/validation failure (which
    // 851-2430 maps to exit code 2, "usage", regardless of ArgumentParser's own EX_USAGE=64
    // default for the same failure).
    //
    // NOTE: `exit` is qualified as `Foundation.exit` throughout this method because an unqualified
    // `exit(...)` here resolves to `ParsableCommand`'s own static `exit(withError:)` (inherited via
    // `Self`, which takes priority over the global Darwin/Foundation `exit(_:)` in this static
    // method's lookup), not the process-terminating global function we actually want.
    let message = fullMessage(for: error)
    if Lilpw.exitCode(for: error) == .success {
      if !message.isEmpty { print(message) }
      Foundation.exit(LilpwExitCode.ok.rawValue)
    } else {
      if !message.isEmpty {
        FileHandle.standardError.write(Data((message + "\n").utf8))
      }
      Foundation.exit(LilpwExitCode.usage.rawValue)
    }
  }
}
