import Foundation
import LilPasswordsKit

// Placeholder CLI. Real commands arrive in 851-2430.
let arguments = CommandLine.arguments.dropFirst()
if arguments.contains("--version") {
  let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
  print("\(LilPasswordsKit.cliName) \(version)")
} else {
  print("usage: \(LilPasswordsKit.cliName) --version")
}
