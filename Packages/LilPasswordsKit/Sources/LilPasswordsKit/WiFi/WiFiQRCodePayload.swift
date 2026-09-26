import Foundation

/// Builds the `WIFI:...;;` QR payload string (the same convention Wi-Fi Alliance / ZXing / iOS's
/// and macOS's own Camera-based Wi-Fi QR reader all use) for sharing a known network's credentials
/// as a scannable code.
public enum WiFiQRCodePayload {
  /// - Parameters:
  ///   - ssid: The network name. Escaped per the QR-payload convention below.
  ///   - password: The already-revealed password, kept only in memory by the caller. Ignored
  ///     (the `P:` field is omitted entirely) when `security` is `.none`, matching how every real
  ///     scanner expects an open network's payload to look.
  ///   - security: Determines the payload's `T:` field via
  ///     ``WiFiNetworkSecurity/qrAuthenticationType``.
  public static func payload(ssid: String, password: String?, security: WiFiNetworkSecurity) -> String {
    let type = security.qrAuthenticationType
    let escapedSSID = escaping(ssid)
    guard type != "nopass" else {
      return "WIFI:T:nopass;S:\(escapedSSID);;"
    }
    let escapedPassword = escaping(password ?? "")
    return "WIFI:T:\(type);S:\(escapedSSID);P:\(escapedPassword);;"
  }

  /// Escapes `\`, `;`, `,`, and `:` — the characters the QR-payload convention reserves as field
  /// delimiters/escapes — by prefixing each with a backslash. Scans the *original* string once
  /// left to right and appends to a fresh result, so a literal backslash already present in the
  /// SSID/password is itself escaped to `\\` without that escaping backslash then being
  /// re-escaped: this function never re-scans its own output.
  ///
  /// The input here is always an SSID or password: arbitrary user-chosen text, never anything this
  /// app treats as instructions no matter what it says (see ``WiFiNetworkParsing``'s doc comment).
  static func escaping(_ string: String) -> String {
    var result = ""
    result.reserveCapacity(string.count)
    for character in string {
      switch character {
      case "\\", ";", ",", ":":
        result.append("\\")
        result.append(character)
      default:
        result.append(character)
      }
    }
    return result
  }
}
