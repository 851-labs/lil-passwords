import ArgumentParser
import LilPasswordsKit
import LilpwCore

struct ReadCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "read",
    abstract: "Resolve a lilpw://item/field secret reference and print its value.",
    discussion: """
      Modeled on `op read`'s `op://vault/item/field` references, e.g.:
        lilpw read lilpw://github.com/password
      """
  )

  @Argument(help: "A lilpw://<item>/<field> reference.")
  var reference: String

  @OptionGroup var jsonOutput: JSONOutputOptions

  func run() async throws {
    guard let parsedReference = SecretReference(string: reference) else {
      throw LilpwError(exitCode: .usage, message: "not a valid lilpw:// reference: \"\(reference)\"")
    }
    let value = try await LilpwCommands.read(client: AgentClient(), reference: parsedReference)
    Output.print(value, asJSON: jsonOutput.json) { value in print(value.value) }
  }
}
