import ArgumentParser
import Foundation
import LilPasswordsKit
import LilpassCore

struct InjectCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "inject",
    abstract: "Replace {{ lilpass://item/field }} placeholders in a template file with resolved secrets.",
    discussion: """
      Every placeholder is resolved before any substitution happens — if any one of them fails
      (locked, not found, ambiguous, malformed), nothing is written to --output. See
      LilpassInject.inject's documentation for why a partially-filled-in output is worse than none.
      """
  )

  @Option(name: .shortAndLong, help: "The template file to read.")
  var input: String

  @Option(name: .shortAndLong, help: "Where to write the substituted output. Overwritten if it exists.")
  var output: String

  @OptionGroup var jsonOutput: JSONOutputOptions

  func run() async throws {
    let template: String
    do {
      template = try String(contentsOf: URL(fileURLWithPath: input), encoding: .utf8)
    } catch {
      throw LilpassError(exitCode: .usage, message: "couldn't read \"\(input)\": \(error)")
    }

    let injected = try await LilpassInject.inject(template: template, client: AgentClient())

    do {
      try injected.write(to: URL(fileURLWithPath: output), atomically: true, encoding: .utf8)
    } catch {
      throw LilpassError(exitCode: .generic, message: "couldn't write \"\(output)\": \(error)")
    }

    // Like `run`, `--json` has no real effect here beyond a consistent, machine-readable
    // confirmation — there's no secret-bearing result to format either way.
    Output.print(InjectResult(output: output), asJSON: jsonOutput.json) { result in
      print("wrote \(result.output)")
    }
  }
}

private struct InjectResult: Encodable {
  let output: String
}
