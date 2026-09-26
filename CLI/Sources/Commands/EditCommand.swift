import ArgumentParser
import LilPasswordsKit
import LilpassCore

struct EditCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "edit",
    abstract: "Edit an existing item.",
    discussion: """
      Only the fields you pass are changed; everything else on the item is left as-is. --username
      and --website each replace that field's whole list when given at all (there's no way to
      append a single extra username/website without re-listing the others).

      Like `add`, the password can only change via --password - (reads the new password from
      stdin) or --generate — never a literal --password value, and requires agent write access
      (851-2433).
      """
  )

  @Argument(help: "An item's id, exact title (case-insensitive), or website domain.")
  var item: String

  @Option(name: .long, help: "Replace the item's title.")
  var title: String?

  @Option(name: .long, parsing: .singleValue, help: "Replace the item's usernames. May be repeated.")
  var username: [String] = []

  @Option(
    name: .long,
    help: "Pass - to read the new password from stdin. Never a literal value; use --generate instead."
  )
  var password: String?

  @Flag(name: .long, help: "Generate a new password instead of supplying --password.")
  var generate = false

  @Option(name: .long, help: "Exact length for --generate. Defaults to Apple's \"Strong Password\" format.")
  var length: Int?

  @Flag(name: .long, help: "Exclude symbols from a --generate password. Only applies with --length.")
  var noSymbols = false

  @Option(name: .long, parsing: .singleValue, help: "Replace the item's websites. May be repeated.")
  var website: [String] = []

  @Option(name: .long, help: "Replace the item's notes.")
  var notes: String?

  @Option(name: .long, help: "Replace the item's group/folder.")
  var group: String?

  @OptionGroup var jsonOutput: JSONOutputOptions

  func validate() throws {
    if generate {
      guard password == nil else {
        throw ValidationError("--password and --generate can't both be given.")
      }
    } else if let password {
      guard password == "-" else {
        throw ValidationError(
          "--password must be exactly - (to read the new password from stdin), or pass --generate instead. "
            + "A literal password here would leak into `ps` output."
        )
      }
    }
  }

  func run() async throws {
    let client = AgentClient()
    let resolvedPassword: String?
    if generate {
      resolvedPassword = try await LilpassCommands.generate(client: client, length: length, noSymbols: noSymbols)
    } else if password != nil {
      resolvedPassword = try StandardInput.readPassword()
    } else {
      resolvedPassword = nil
    }

    let updated = try await LilpassCommands.edit(
      client: client,
      identifier: item,
      title: title,
      usernames: username,
      password: resolvedPassword,
      websites: website,
      notes: notes,
      group: group
    )
    Output.print(updated, asJSON: jsonOutput.json) { summary in
      print("updated \"\(summary.title)\" (\(summary.id))")
    }
  }
}
