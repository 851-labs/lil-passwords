import Testing

@testable import LilPasswordsKit

@Suite struct AgentMCPServerSpecTests {
  @Test func matchesThePrimaryCommand() {
    let spec = AgentMCPServerSpec(name: "lilpass", command: "/usr/local/bin/lilpass", args: ["mcp"])
    #expect(spec.matches(command: "/usr/local/bin/lilpass"))
  }

  @Test func matchesAnAlternateCommand() {
    let spec = AgentMCPServerSpec(
      name: "lilpass",
      command: "/usr/local/bin/lilpass",
      args: ["mcp"],
      alternateCommands: ["/Applications/lil passwords.app/Contents/Helpers/lilpass"]
    )
    #expect(spec.matches(command: "/Applications/lil passwords.app/Contents/Helpers/lilpass"))
  }

  @Test func doesNotMatchAnUnrelatedCommand() {
    let spec = AgentMCPServerSpec(
      name: "lilpass",
      command: "/usr/local/bin/lilpass",
      args: ["mcp"],
      alternateCommands: ["/Users/someone/.local/bin/lilpass"]
    )
    #expect(!spec.matches(command: "/some/other/tool"))
  }

  @Test func defaultAlternateCommandsIsEmpty() {
    #expect(AgentMCPServerSpec.lilpass.alternateCommands.isEmpty)
  }
}
