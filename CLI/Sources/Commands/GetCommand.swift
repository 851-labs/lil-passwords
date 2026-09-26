import ArgumentParser
import LilPasswordsKit
import LilpassCore

struct GetCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "get",
    abstract: "Get an item's full details, or a single field's value with --field.",
    discussion: """
      With no --field, prints the full item, including its password and notes — this is one of
      851-2430's explicit secret-revealing commands, alongside `read` and `totp`.
      """
  )

  @Argument(help: "An item's id, exact title (case-insensitive), or website domain.")
  var item: String

  @Option(name: .long, help: "Print just this field's value instead of the full item.")
  var field: ItemField?

  @OptionGroup var jsonOutput: JSONOutputOptions

  func run() async throws {
    let client = AgentClient()
    if let field {
      let value = try await LilpassCommands.getField(client: client, identifier: item, field: field)
      Output.print(value, asJSON: jsonOutput.json) { value in print(value.value) }
    } else {
      let detail = try await LilpassCommands.getDetail(client: client, identifier: item)
      Output.print(detail, asJSON: jsonOutput.json) { detail in
        print("title: \(detail.title)")
        if let username = detail.usernames.first { print("username: \(username)") }
        print("password: \(detail.password)")
        if let website = detail.websites.first { print("website: \(website)") }
        if let group = detail.group { print("group: \(group)") }
        if !detail.notes.isEmpty { print("notes: \(detail.notes)") }
        print("hasTOTP: \(detail.hasTOTP)")
      }
    }
  }
}
