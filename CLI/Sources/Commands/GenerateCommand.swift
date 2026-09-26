import ArgumentParser
import LilPasswordsKit
import LilpassCore

struct GenerateCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "generate",
    abstract: "Generate a new password.",
    discussion: """
      With no --length, generates Apple's "Strong Password" format (xxxxxx-xxxxxx-xxxxxx). With
      --length, generates a password of exactly that many characters instead.
      """
  )

  @Option(name: .long, help: "Exact password length. Defaults to Apple's \"Strong Password\" format.")
  var length: Int?

  @Flag(name: .long, help: "Exclude symbols from the generated password. Only applies with --length.")
  var noSymbols = false

  @OptionGroup var jsonOutput: JSONOutputOptions

  func run() async throws {
    let password = try await LilpassCommands.generate(client: AgentClient(), length: length, noSymbols: noSymbols)
    Output.print(password, asJSON: jsonOutput.json) { password in print(password) }
  }
}
