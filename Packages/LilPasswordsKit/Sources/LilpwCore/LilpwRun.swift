import Foundation
import LilPasswordsKit

/// `lilpw run --env KEY=lilpw://item/field -- <cmd> [args...]`: resolves every `--env` secret
/// reference, then execs `<cmd>` with those key/value pairs injected into its environment.
public enum LilpwRun {
  /// Parses one `--env` argument's `KEY=lilpw://item/field` shape.
  public static func parseAssignment(_ raw: String) throws -> (key: String, reference: SecretReference) {
    guard let equalsIndex = raw.firstIndex(of: "=") else {
      throw LilpwError(exitCode: .usage, message: "--env expects KEY=lilpw://item/field, got \"\(raw)\"")
    }
    let key = String(raw[raw.startIndex..<equalsIndex])
    let referenceString = String(raw[raw.index(after: equalsIndex)...])
    guard !key.isEmpty, let reference = SecretReference(string: referenceString) else {
      throw LilpwError(exitCode: .usage, message: "--env expects KEY=lilpw://item/field, got \"\(raw)\"")
    }
    return (key, reference)
  }

  /// Resolves every `--env` assignment to its secret value. The returned dictionary is meant to be
  /// overlaid on the child process's environment, never printed or logged.
  public static func resolveEnvironment(_ assignments: [String], client: AgentClient) async throws -> [String:
    String]
  {
    var resolved: [String: String] = [:]
    for raw in assignments {
      let (key, reference) = try parseAssignment(raw)
      let item = try await LilpwCommands.resolveItem(reference.item, client: client)
      resolved[key] = try await SecretResolver.value(for: reference.field, in: item, client: client)
    }
    return resolved
  }

  /// Execs `executable` (resolved against `PATH` via `/usr/bin/env`, matching a shell's own lookup)
  /// with `arguments`, its environment the current process's own environment overlaid with `env`,
  /// and stdio inherited unmodified — `lilpw run` itself never reads or prints the child's output,
  /// so a resolved secret only ever reaches the child as an environment variable.
  ///
  /// - Returns: The child's exit code, unmodified. `lilpw run`'s own exit code is always the
  ///   command's exit code, not one of `LilpwExitCode`'s cases (that's why this returns a plain
  ///   `Int32` rather than throwing on a nonzero exit).
  /// - Throws: `LilpwError` (exit code `.generic`) if `executable` can't even be launched.
  public static func run(executable: String, arguments: [String], env: [String: String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments

    var environment = ProcessInfo.processInfo.environment
    for (key, value) in env {
      environment[key] = value
    }
    process.environment = environment

    do {
      try process.run()
    } catch {
      throw LilpwError(exitCode: .generic, message: "couldn't run \"\(executable)\": \(error)")
    }
    process.waitUntilExit()
    return process.terminationStatus
  }
}
