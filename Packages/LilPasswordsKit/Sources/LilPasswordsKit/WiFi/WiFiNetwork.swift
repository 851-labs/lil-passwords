import Foundation

/// A Wi-Fi network this Mac already knows about, per `docs/adr/0005-wifi-passwords.md` — either
/// because it's one of the networks macOS remembers joining (`networksetup
/// -listpreferredwirelessnetworks`), or the one it's currently associated with
/// (`system_profiler SPAirPortDataType`, when that's reliably available).
///
/// Deliberately holds no password — this app never keeps a Wi-Fi password anywhere but a
/// short-lived in-memory value the moment it's revealed (see ``WiFiPasswordRevealing``). Nothing
/// about a network's password is ever written to the vault, a log, or this type.
public struct WiFiNetwork: Sendable, Equatable, Identifiable {
  public var id: String { ssid }

  public var ssid: String

  /// Whether this is the network the Mac is currently associated with. Badged in the UI, same as
  /// Apple Passwords' own Wi-Fi list.
  public var isCurrentNetwork: Bool

  /// The network's authentication scheme, when this Mac happens to know it — only ever true for
  /// the current network, or a known network close enough to also show up in a live scan (see
  /// ``WiFiNetworkParsing/parseSystemProfilerInfo(fromJSON:device:)``). `nil` otherwise: this app
  /// has no entitlement-free way to ask "what security does network X use" for an arbitrary known
  /// network that isn't currently in range.
  public var security: WiFiNetworkSecurity?

  public init(ssid: String, isCurrentNetwork: Bool = false, security: WiFiNetworkSecurity? = nil) {
    self.ssid = ssid
    self.isCurrentNetwork = isCurrentNetwork
    self.security = security
  }
}
