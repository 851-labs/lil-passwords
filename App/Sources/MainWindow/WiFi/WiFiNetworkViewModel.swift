import Combine
import Foundation
import LilPasswordsKit

/// Publishes the Wi-Fi category's known networks and reveals a network's password on demand.
///
/// `WiFiNetworkListing`/`WiFiPasswordRevealing` (`LilPasswordsKit`) are deliberately synchronous —
/// both shell out via a blocking `Process` call — so this is the one place that hop off the main
/// actor happens, via `Task.detached`, so neither a `knownNetworks()` scan nor (especially) a
/// `security find-generic-password` call that's about to show macOS's own admin-authentication
/// dialog ever blocks the UI thread.
///
/// A revealed password is handed back to the caller and published nowhere by this class — it's
/// held only by whichever `WiFiPasswordRowView` requested it, for exactly as long as that row
/// shows it on screen. See `docs/adr/0006-wifi-passwords.md`.
@MainActor
final class WiFiNetworkViewModel: ObservableObject {
  @Published private(set) var networks: [WiFiNetwork] = []

  private let listing: any WiFiNetworkListing
  private let revealing: any WiFiPasswordRevealing

  init(
    listing: any WiFiNetworkListing = SystemWiFiNetworkListing(),
    revealing: any WiFiPasswordRevealing = SystemWiFiPasswordRevealing()
  ) {
    self.listing = listing
    self.revealing = revealing
  }

  /// Re-scans known Wi-Fi networks. Safe to call repeatedly (e.g. every time the Wi-Fi sidebar
  /// category is selected) — `SystemWiFiNetworkListing` itself is a handful of quick, read-only CLI
  /// calls with no caching to invalidate.
  func refresh() async {
    let listing = self.listing
    var networks = await Task.detached { listing.knownNetworks() }.value
    #if DEBUG
      if Self.isDebugFakeNetworkEnabled {
        networks.insert(Self.debugFakeNetwork, at: 0)
      }
    #endif
    self.networks = networks
  }

  /// Reveals `network`'s saved password — triggers macOS's own admin-authentication dialog the
  /// first time this process asks for it. Throws ``WiFiPasswordRevealError`` on cancellation,
  /// denial, or "no such saved password."
  func revealPassword(for network: WiFiNetwork) async throws -> String {
    #if DEBUG
      if Self.isDebugFakeNetworkEnabled, network.ssid == Self.debugFakeNetwork.ssid {
        return Self.debugFakeNetworkPassword
      }
    #endif
    let revealing = self.revealing
    let ssid = network.ssid
    return try await Task.detached { try revealing.password(forSSID: ssid) }.value
  }

  #if DEBUG
    /// `-WiFiDebugFakeNetwork YES` prepends this one synthetic network to whatever real known
    /// networks this Mac reports, and makes revealing its password return a canned value instantly
    /// — no real System keychain lookup, no real admin-authentication prompt. DEBUG-only, exists so
    /// a tophat/manual-QA capture of the Wi-Fi list, detail card, reveal, and QR sheet can be
    /// scripted end-to-end without a real saved Wi-Fi network or anyone's actual admin password —
    /// matching this app's existing `-InitialSidebarCategory`/`-AutoUnlockForTophat` launch-argument
    /// conventions (see `MainWindowController`). Never compiled into Release builds.
    static let debugFakeNetwork = WiFiNetwork(
      ssid: "Debug Fake Network",
      isCurrentNetwork: true,
      security: .wpa2Personal
    )
    static let debugFakeNetworkPassword = "debug-fake-password-123"

    private static var isDebugFakeNetworkEnabled: Bool {
      UserDefaults.standard.bool(forKey: "WiFiDebugFakeNetwork")
    }
  #endif
}
