import Foundation
import LilPasswordsKit

/// `lilpass run --env KEY=lilpass://item/field -- <cmd> [args...]`: resolves every `--env` secret
/// reference, then execs `<cmd>` with those key/value pairs injected into its environment.
public enum LilpassRun {
  /// Parses one `--env` argument's `KEY=lilpass://item/field` shape.
  public static func parseAssignment(_ raw: String) throws -> (key: String, reference: SecretReference) {
    guard let equalsIndex = raw.firstIndex(of: "=") else {
      throw LilpassError(exitCode: .usage, message: "--env expects KEY=lilpass://item/field, got \"\(raw)\"")
    }
    let key = String(raw[raw.startIndex..<equalsIndex])
    let referenceString = String(raw[raw.index(after: equalsIndex)...])
    guard !key.isEmpty, let reference = SecretReference(string: referenceString) else {
      throw LilpassError(exitCode: .usage, message: "--env expects KEY=lilpass://item/field, got \"\(raw)\"")
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
      let item = try await LilpassCommands.resolveItem(reference.item, client: client)
      resolved[key] = try await SecretResolver.value(for: reference.field, in: item, client: client)
    }
    return resolved
  }

  /// Execs `executable` (resolved against `PATH` via `/usr/bin/env`, matching a shell's own lookup)
  /// with `arguments`, its environment the current process's own environment overlaid with `env`,
  /// and stdio inherited unmodified — `lilpass run` itself never reads or prints the child's output,
  /// so a resolved secret only ever reaches the child as an environment variable.
  ///
  /// - Returns: The child's exit code, unmodified. `lilpass run`'s own exit code is always the
  ///   command's exit code, not one of `LilpassExitCode`'s cases (that's why this returns a plain
  ///   `Int32` rather than throwing on a nonzero exit).
  /// - Throws: `LilpassError` (exit code `.generic`) if `executable` can't even be launched.
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
      throw LilpassError(exitCode: .generic, message: "couldn't run \"\(executable)\": \(error)")
    }
    process.waitUntilExit()
    return process.terminationStatus
  }
}
