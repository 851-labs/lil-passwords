import Foundation

/// Discovers Wi-Fi networks this Mac already knows about. Deliberately synchronous — every
/// conformer shells out via a blocking `Process` call, with no async system API to bridge to, so
/// the async hop (when one is wanted, e.g. off the main actor) is left to callers via
/// `Task.detached`, rather than this protocol wrapping `Process` in a continuation itself.
public protocol WiFiNetworkListing: Sendable {
  /// Returns every network macOS remembers joining, badging whichever one (if any) this Mac is
  /// currently associated with and filling in a security type wherever this app can learn one
  /// without any restricted entitlement. Never throws: any individual command failing just means
  /// less information (or an empty list), not an error to surface — this mirrors how Apple's own
  /// Passwords app quietly shows nothing rather than erroring when Wi-Fi is off.
  func knownNetworks() -> [WiFiNetwork]
}

/// The real conformer: shells out to `networksetup` and `system_profiler`, both usable without
/// admin rights or any restricted entitlement. See `docs/adr/0006-wifi-passwords.md` for why this
/// app uses these CLI tools rather than CoreWLAN.
public struct SystemWiFiNetworkListing: WiFiNetworkListing {
  private let runner: any WiFiSystemCommandRunning

  public init(runner: any WiFiSystemCommandRunning = RealWiFiSystemCommandRunner()) {
    self.runner = runner
  }

  public func knownNetworks() -> [WiFiNetwork] {
    guard let device = wifiDeviceName() else { return [] }
    let ssids = preferredNetworkSSIDs(device: device)
    guard !ssids.isEmpty else { return [] }

    let info = systemProfilerInfo(device: device)
    return ssids.map { ssid in
      WiFiNetwork(ssid: ssid, isCurrentNetwork: info.currentSSID == ssid, security: info.securityBySSID[ssid])
    }
  }

  private func wifiDeviceName() -> String? {
    guard let output = try? runner.run(executable: "/usr/sbin/networksetup", arguments: ["-listallhardwareports"])
    else { return nil }
    return WiFiNetworkParsing.parseWiFiDeviceName(fromHardwarePortsOutput: output)
  }

  private func preferredNetworkSSIDs(device: String) -> [String] {
    guard
      let output = try? runner.run(
        executable: "/usr/sbin/networksetup",
        arguments: ["-listpreferredwirelessnetworks", device]
      )
    else { return [] }
    return WiFiNetworkParsing.parsePreferredNetworks(fromOutput: output)
  }

  private func systemProfilerInfo(device: String) -> WiFiNetworkParsing.SystemProfilerInfo {
    guard
      let output = try? runner.run(executable: "/usr/sbin/system_profiler", arguments: ["SPAirPortDataType", "-json"])
    else { return WiFiNetworkParsing.SystemProfilerInfo() }
    return WiFiNetworkParsing.parseSystemProfilerInfo(fromJSON: output, device: device)
  }
}
