import ArgumentParser
import LilPasswordsKit
import LilpassCore

struct ReadCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "read",
    abstract: "Resolve a lilpass://item/field secret reference and print its value.",
    discussion: """
      Modeled on `op read`'s `op://vault/item/field` references, e.g.:
        lilpass read lilpass://github.com/password
      """
  )

  @Argument(help: "A lilpass://<item>/<field> reference.")
  var reference: String

  @OptionGroup var jsonOutput: JSONOutputOptions

  func run() async throws {
    guard let parsedReference = SecretReference(string: reference) else {
      throw LilpassError(exitCode: .usage, message: "not a valid lilpass:// reference: \"\(reference)\"")
    }
    let value = try await LilpassCommands.read(client: AgentEndpoint.makeClient(), reference: parsedReference)
    Output.print(value, asJSON: jsonOutput.json) { value in print(value.value) }
  }
}
