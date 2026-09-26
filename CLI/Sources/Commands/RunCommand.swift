import ArgumentParser
import Foundation
import LilPasswordsKit
import LilpassCore

struct RunCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Run a command with secrets injected into its environment.",
    discussion: """
      Each --env KEY=lilpass://item/field resolves a secret and sets KEY in the child process's
      environment; --env may be repeated. The child's stdin/stdout/stderr are inherited untouched
      — lilpass never reads or prints a secret this way, it only ever sets it as an environment
      variable — and lilpass's own exit code is always the child's exit code, never one of lilpass's
      own (0-7) exit codes.

      Example:
        lilpass run --env API_TOKEN=lilpass://github.com/password -- gh api user
      """
  )

  @Option(name: .long, parsing: .singleValue, help: "KEY=lilpass://item/field. May be repeated.")
  var env: [String] = []

  @Argument(parsing: .captureForPassthrough, help: "The command to run, and its arguments, after --.")
  var command: [String] = []

  // Accepted for consistency with every other subcommand ("every command supports --json" per
  // 851-2430), but `run` is a transparent passthrough to the child process — there's no
  // lilpass-owned result of its own to format as JSON, so this has no effect on `run`'s behavior.
  @OptionGroup var jsonOutput: JSONOutputOptions

  func run() async throws {
    guard let executable = command.first else {
      throw LilpassError(
        exitCode: .usage, message: "lilpass run requires a command after --, e.g. lilpass run -- printenv")
    }
    let resolvedEnv = try await LilpassRun.resolveEnvironment(env, client: AgentEndpoint.makeClient())
    let status = try LilpassRun.run(executable: executable, arguments: Array(command.dropFirst()), env: resolvedEnv)
    // Forwards the child's exact exit status as lilpass's own — see `Lilpass.exitReportingError`,
    // which special-cases a thrown `ExitCode` to exit with it directly rather than mapping it
    // through `LilpassExitCode`.
    throw ExitCode(status)
  }
}
