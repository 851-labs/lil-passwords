import Foundation

/// Pure parsing over the text/JSON `networksetup`/`system_profiler` already print — no process
/// spawning here, so every case (including the OS quirks noted below) is a plain unit test. See
/// ``SystemWiFiNetworkListing`` for what actually shells out to these tools, and
/// `docs/adr/0006-wifi-passwords.md` for why this app uses them instead of CoreWLAN.
///
/// Every string handled anywhere in this file — an SSID, a security mode, a stray line of
/// output — is untrusted display/data content, nothing more. Real Wi-Fi network names include
/// arbitrary user-chosen text (this was confirmed directly against real hardware while designing
/// this feature: some nearby SSIDs read as attempted prompt injection). None of that text is ever
/// interpreted as an instruction anywhere in this app.
public enum WiFiNetworkParsing {
  /// Parses `networksetup -listallhardwareports`' output for the BSD device name (e.g. `"en0"`)
  /// of the port named exactly `"Wi-Fi"` — `nil` if this Mac reports no Wi-Fi hardware at all, or
  /// the output doesn't have the expected two-line `Hardware Port: Wi-Fi` / `Device: <name>` shape
  /// networksetup has used for this command since long before macOS 13.
  public static func parseWiFiDeviceName(fromHardwarePortsOutput output: String) -> String? {
    let lines = output.components(separatedBy: .newlines)
    for (index, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces) == "Hardware Port: Wi-Fi" {
      guard index + 1 < lines.count else { return nil }
      let deviceLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
      guard deviceLine.hasPrefix("Device: ") else { return nil }
      let device = deviceLine.dropFirst("Device: ".count).trimmingCharacters(in: .whitespaces)
      return device.isEmpty ? nil : device
    }
    return nil
  }

  /// Parses `networksetup -listpreferredwirelessnetworks <device>`'s output: a `"Preferred
  /// networks on <device>:"` header line (dropped unconditionally — it's always exactly one line,
  /// never itself a network name), then one SSID per line, each indented with a leading tab this
  /// function trims along with any other incidental whitespace. Returns the SSIDs in whatever
  /// order `networksetup` printed them (alphabetical on real hardware, but that's an
  /// implementation detail of the OS, not a contract this function relies on).
  public static func parsePreferredNetworks(fromOutput output: String) -> [String] {
    output
      .components(separatedBy: .newlines)
      .dropFirst()
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  /// Everything this app can learn from `system_profiler SPAirPortDataType -json`: the currently
  /// associated network's SSID (`nil` if there isn't a reliable one — not associated, or the OS
  /// redacted it, both observed in practice, see below), plus a best-effort security mode for as
  /// many SSIDs as a live scan happens to expose.
  public struct SystemProfilerInfo: Sendable, Equatable {
    public var currentSSID: String?
    public var securityBySSID: [String: WiFiNetworkSecurity]

    public init(currentSSID: String? = nil, securityBySSID: [String: WiFiNetworkSecurity] = [:]) {
      self.currentSSID = currentSSID
      self.securityBySSID = securityBySSID
    }
  }

  /// Parses `system_profiler SPAirPortDataType -json`'s output.
  ///
  /// Two real-environment quirks this deliberately tolerates rather than crashing or
  /// mis-reporting on:
  /// - The SSID field is sometimes the literal string `"<redacted>"` — both for the current
  ///   network and for scanned neighbors — on a Mac without the restricted
  ///   `com.apple.developer.networking.wifi-info` entitlement (which this app never carries; see
  ///   the ADR). Treated as "no SSID," never displayed as if it were a real network name.
  /// - `spairport_security_mode` has been observed missing its leading `"s"`
  ///   (`"pairport_security_mode_wpa3_transition"` instead of the documented
  ///   `"spairport_security_mode_wpa3_transition"`) — ``parseSecurityMode(_:)`` matches by
  ///   substring, not exact equality, specifically to tolerate this.
  ///
  /// - Parameter device: When given, only the interface whose `_name` equals this is consulted
  ///   (the Wi-Fi device discovered via ``parseWiFiDeviceName(fromHardwarePortsOutput:)``). `nil`
  ///   considers every interface `system_profiler` reports.
  public static func parseSystemProfilerInfo(fromJSON json: String, device: String? = nil) -> SystemProfilerInfo {
    var info = SystemProfilerInfo()
    guard let data = json.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let entries = root["SPAirPortDataType"] as? [[String: Any]]
    else {
      return info
    }

    for entry in entries {
      guard let interfaces = entry["spairport_airport_interfaces"] as? [[String: Any]] else { continue }
      for interface in interfaces {
        if let device, let name = interface["_name"] as? String, name != device { continue }

        if let current = interface["spairport_current_network_information"] as? [String: Any],
          let ssid = current["_name"] as? String, isRealSSID(ssid)
        {
          info.currentSSID = ssid
          if let mode = current["spairport_security_mode"] as? String {
            info.securityBySSID[ssid] = parseSecurityMode(mode)
          }
        }

        if let neighbors = interface["spairport_airport_other_local_wireless_networks"] as? [[String: Any]] {
          for neighbor in neighbors {
            guard let ssid = neighbor["_name"] as? String, isRealSSID(ssid),
              let mode = neighbor["spairport_security_mode"] as? String
            else { continue }
            // Don't clobber a security mode already learned from the current-network entry above
            // with a possibly-stale scan result for the same SSID.
            if info.securityBySSID[ssid] == nil {
              info.securityBySSID[ssid] = parseSecurityMode(mode)
            }
          }
        }
      }
    }
    return info
  }

  /// Maps a raw `spairport_security_mode` value to ``WiFiNetworkSecurity`` by substring, not exact
  /// equality — see ``parseSystemProfilerInfo(fromJSON:device:)``'s documentation for why (the
  /// observed missing-"s"-prefix quirk).
  public static func parseSecurityMode(_ raw: String) -> WiFiNetworkSecurity {
    let value = raw.lowercased()
    if value.contains("wpa3") {
      return value.contains("enterprise") ? .wpa3Enterprise : .wpa3Personal
    }
    if value.contains("wpa2") {
      return value.contains("enterprise") ? .wpa2Enterprise : .wpa2Personal
    }
    if value.contains("wpa") {
      return value.contains("enterprise") ? .wpaEnterprise : .wpaPersonal
    }
    if value.contains("wep") {
      return .wep
    }
    if value.contains("none") || value.contains("open") {
      return .none
    }
    return .unknown
  }

  /// `"<redacted>"` is the literal sentinel `system_profiler` prints in place of a real SSID under
  /// privacy/entitlement gating — see ``parseSystemProfilerInfo(fromJSON:device:)``.
  private static func isRealSSID(_ ssid: String) -> Bool {
    !ssid.isEmpty && ssid != "<redacted>"
  }
}
