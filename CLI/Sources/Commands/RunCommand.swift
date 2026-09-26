import ArgumentParser
import Foundation
import LilPasswordsKit
import LilpwCore

struct RunCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Run a command with secrets injected into its environment.",
    discussion: """
      Each --env KEY=lilpw://item/field resolves a secret and sets KEY in the child process's
      environment; --env may be repeated. The child's stdin/stdout/stderr are inherited untouched
      — lilpw never reads or prints a secret this way, it only ever sets it as an environment
      variable — and lilpw's own exit code is always the child's exit code, never one of lilpw's
      own (0-7) exit codes.

      Example:
        lilpw run --env API_TOKEN=lilpw://github.com/password -- gh api user
      """
  )

  @Option(name: .long, parsing: .singleValue, help: "KEY=lilpw://item/field. May be repeated.")
  var env: [String] = []

  @Argument(parsing: .captureForPassthrough, help: "The command to run, and its arguments, after --.")
  var command: [String] = []

  // Accepted for consistency with every other subcommand ("every command supports --json" per
  // 851-2430), but `run` is a transparent passthrough to the child process — there's no
  // lilpw-owned result of its own to format as JSON, so this has no effect on `run`'s behavior.
  @OptionGroup var jsonOutput: JSONOutputOptions

  func run() async throws {
    guard let executable = command.first else {
      throw LilpwError(exitCode: .usage, message: "lilpw run requires a command after --, e.g. lilpw run -- printenv")
    }
    let resolvedEnv = try await LilpwRun.resolveEnvironment(env, client: AgentClient())
    let status = try LilpwRun.run(executable: executable, arguments: Array(command.dropFirst()), env: resolvedEnv)
    // Forwards the child's exact exit status as lilpw's own — see `Lilpw.exitReportingError`,
    // which special-cases a thrown `ExitCode` to exit with it directly rather than mapping it
    // through `LilpwExitCode`.
    throw ExitCode(status)
  }
}
