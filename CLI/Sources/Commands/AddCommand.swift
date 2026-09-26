import ArgumentParser
import LilPasswordsKit
import LilpassCore

struct AddCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add",
    abstract: "Add a new item to the vault.",
    discussion: """
      Requires agent write access, a separate Settings → Agents toggle from plain read access
      (851-2433) — fails with a dedicated exit code while it's off, same as any other agent.

      The password is never a plain command-line argument: pass --password - to read it from
      stdin (e.g. `echo -n hunter2 | lilpass add --title GitHub --username octocat --password -`),
      or pass --generate to have lilpass generate one instead. A literal --password value is
      rejected — anything else would end up readable in `ps` output to any other user on the
      machine for as long as the process runs.
      """
  )

  @Option(name: .long, help: "The item's title.")
  var title: String

  @Option(name: .long, parsing: .singleValue, help: "A username or account identifier. May be repeated.")
  var username: [String] = []

  @Option(
    name: .long,
    help: "Pass - to read the password from stdin. Never a literal value; use --generate instead."
  )
  var password: String?

  @Flag(name: .long, help: "Generate a password instead of supplying --password.")
  var generate = false

  @Option(name: .long, help: "Exact length for --generate. Defaults to Apple's \"Strong Password\" format.")
  var length: Int?

  @Flag(name: .long, help: "Exclude symbols from a --generate password. Only applies with --length.")
  var noSymbols = false

  @Option(name: .long, parsing: .singleValue, help: "A website URL or domain. May be repeated.")
  var website: [String] = []

  @Option(name: .long, help: "Free-text notes.")
  var notes = ""

  @Option(name: .long, help: "The group/folder this item belongs to.")
  var group: String?

  @OptionGroup var jsonOutput: JSONOutputOptions

  func validate() throws {
    if generate {
      guard password == nil else {
        throw ValidationError("--password and --generate can't both be given.")
      }
    } else {
      guard password == "-" else {
        throw ValidationError(
          "--password must be exactly - (to read the password from stdin), or pass --generate instead. "
            + "A literal password here would leak into `ps` output."
        )
      }
    }
  }

  func run() async throws {
    let client = AgentClient()
    let resolvedPassword: String
    if generate {
      resolvedPassword = try await LilpassCommands.generate(client: client, length: length, noSymbols: noSymbols)
    } else {
      resolvedPassword = try StandardInput.readPassword()
    }

    let created = try await LilpassCommands.add(
      client: client,
      title: title,
      usernames: username,
      password: resolvedPassword,
      websites: website,
      notes: notes,
      group: group
    )
    Output.print(created, asJSON: jsonOutput.json) { summary in
      print("added \"\(summary.title)\" (\(summary.id))")
    }
  }
}
