import Foundation
import LilPasswordsKit

// Placeholder CLI. Real commands arrive in 851-2430.
let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "status" {
  // Hidden ahead of 851-2430's real command surface: talks to the real, launchd-activated Mach
  // service (`AgentClient()`, no arguments — see its documentation) so tophat/manual testing has
  // something to run against `LilPasswordsAgent` before the real CLI commands exist. `lilpw`
  // always goes through XPC rather than touching the vault itself — see
  // docs/adr/0001-storage-and-process-model.md.
  do {
    let status = try await AgentClient().status()
    print("locked: \(status.locked), agentAccessEnabled: \(status.agentAccessEnabled)")
  } catch {
    FileHandle.standardError.write(Data("\(LilPasswordsKit.cliName): \(error)\n".utf8))
    exit(1)
  }
} else if arguments.contains("--version") {
  let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
  print("\(LilPasswordsKit.cliName) \(version)")
} else {
  print("usage: \(LilPasswordsKit.cliName) --version")
}
