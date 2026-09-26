import Foundation

/// Why a Wi-Fi password couldn't be revealed.
public enum WiFiPasswordRevealError: Error, Sendable, Equatable {
  /// No saved password for this SSID in the System keychain. Maps `security
  /// find-generic-password`'s exit code 44, confirmed empirically against a real Mac — see
  /// `docs/adr/0006-wifi-passwords.md`.
  case notFound

  /// The admin-authentication prompt was cancelled or denied, or `security` failed for any other
  /// reason. Carries `security`'s own stderr text (already a short, human-readable sentence)
  /// rather than a message this app invents — there's no documented, stable way to tell "the user
  /// clicked Cancel" apart from "wrong admin password" apart from any other `security` failure
  /// from its exit code alone, and every one of those cases means the same thing to this app:
  /// don't show a password. See the ADR's "Testing" section for what this means for tophat/manual
  /// QA of the reveal flow specifically.
  case failed(String)
}

/// Reveals the saved password for a known Wi-Fi network. Deliberately synchronous, like
/// ``WiFiNetworkListing`` — see that protocol's doc comment for why.
///
/// Nothing that conforms to this protocol may cache, log, or persist a revealed password anywhere
/// beyond the caller's own transient in-memory value. There is intentionally no XPC, CLI, or MCP
/// surface anywhere in this app that calls a conformer of this protocol — Wi-Fi passwords are
/// revealed only from the main app process, only into memory, only on explicit user action. Agents
/// (the `lilpass mcp` server, `Agent/`'s XPC surface, and the `lilpass` CLI) never get Wi-Fi
/// passwords.
public protocol WiFiPasswordRevealing: Sendable {
  /// Prompts for admin authentication (if the OS hasn't already satisfied it for this process) and
  /// returns `ssid`'s saved password.
  func password(forSSID ssid: String) throws -> String
}

/// The real conformer: shells out to `security find-generic-password`, scoped explicitly to the
/// System keychain, which is what triggers macOS's own admin-authentication dialog for an
/// `"AirPort network password"` item. See `docs/adr/0006-wifi-passwords.md` for why this app uses
/// the `security` CLI (Authorization Services under the hood) rather than calling `SecItemCopyMatching`
/// directly.
public struct SystemWiFiPasswordRevealing: WiFiPasswordRevealing {
  /// The well-known path of the System keychain, passed as `security`'s trailing positional
  /// keychain argument so this only ever searches (and prompts for) the System keychain — never
  /// falls back to searching the user's login keychain, where this item would never legitimately
  /// live anyway.
  private static let systemKeychainPath = "/Library/Keychains/System.keychain"

  private let runner: any WiFiSystemCommandRunning

  public init(runner: any WiFiSystemCommandRunning = RealWiFiSystemCommandRunner()) {
    self.runner = runner
  }

  public func password(forSSID ssid: String) throws -> String {
    do {
      let output = try runner.run(
        executable: "/usr/bin/security",
        arguments: [
          "find-generic-password",
          "-D", "AirPort network password",
          "-s", "AirPort",
          "-a", ssid,
          "-w",
          Self.systemKeychainPath,
        ]
      )
      let password = output.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !password.isEmpty else { throw WiFiPasswordRevealError.notFound }
      return password
    } catch let failure as WiFiSystemCommandFailure {
      if failure.exitCode == 44 {
        throw WiFiPasswordRevealError.notFound
      }
      throw WiFiPasswordRevealError.failed(failure.standardError)
    }
  }
}
