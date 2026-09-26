import Foundation

/// The authentication scheme a Wi-Fi network uses, as reported by `system_profiler`'s
/// `spairport_security_mode` values (`spairport_security_mode_wpa2_personal`, etc.) — see
/// ``WiFiNetworkParsing/parseSecurityMode(_:)`` for how those raw strings map to this enum.
///
/// Plain, un-localized display strings, matching this package's existing convention for
/// UI-adjacent data types with no AppKit dependency (see `SecurityIssueKind.groupTitle`) — this
/// package has no localization bundle of its own; the App target is what wraps user-facing text
/// in `String(localized:)`.
public enum WiFiNetworkSecurity: String, Sendable, Equatable, CaseIterable {
  case none
  case wep
  case wpaPersonal
  case wpa2Personal
  case wpa3Personal
  case wpaEnterprise
  case wpa2Enterprise
  case wpa3Enterprise
  case unknown

  /// Short label shown next to a network's name in the list/detail card.
  public var displayName: String {
    switch self {
    case .none: return "Open"
    case .wep: return "WEP"
    case .wpaPersonal: return "WPA Personal"
    case .wpa2Personal: return "WPA2 Personal"
    case .wpa3Personal: return "WPA3 Personal"
    case .wpaEnterprise: return "WPA Enterprise"
    case .wpa2Enterprise: return "WPA2 Enterprise"
    case .wpa3Enterprise: return "WPA3 Enterprise"
    case .unknown: return "Secured"
    }
  }

  /// The `T:` field of a `WIFI:` QR payload (the Wi-Fi Alliance/ZXing convention every major
  /// scanner, including iOS/macOS's own, understands): `"nopass"` for an open network, `"WEP"` for
  /// WEP, `"WPA"` for every WPA/WPA2/WPA3 personal-or-enterprise variant. There's no separate QR
  /// token for WPA2 vs. WPA3 vs. enterprise — real scanners just try the given password against
  /// whatever the AP actually negotiates, so `.unknown` (a real password exists, but this app
  /// never learned which WPA generation) maps to `"WPA"` rather than guessing wrong in the
  /// direction of claiming no password is needed.
  public var qrAuthenticationType: String {
    switch self {
    case .none: return "nopass"
    case .wep: return "WEP"
    case .wpaPersonal, .wpa2Personal, .wpa3Personal, .wpaEnterprise, .wpa2Enterprise, .wpa3Enterprise, .unknown:
      return "WPA"
    }
  }
}
