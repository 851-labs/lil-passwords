import Foundation
import Testing

@testable import LilPasswordsKit

@Suite("WiFiQRCodePayload")
struct WiFiQRCodePayloadTests {
  @Test("builds a WPA payload with SSID and password")
  func wpaPayload() {
    let payload = WiFiQRCodePayload.payload(ssid: "HomeNet", password: "sup3rSecret", security: .wpa2Personal)
    #expect(payload == "WIFI:T:WPA;S:HomeNet;P:sup3rSecret;;")
  }

  @Test("omits the password field entirely for an open network")
  func openNetworkPayload() {
    let payload = WiFiQRCodePayload.payload(ssid: "CafeGuest", password: "ignored", security: .none)
    #expect(payload == "WIFI:T:nopass;S:CafeGuest;;")
  }

  @Test("maps every WPA-family security type to the shared WPA QR token")
  func wpaFamilyToken() {
    for security: WiFiNetworkSecurity in [
      .wpaPersonal, .wpa2Personal, .wpa3Personal, .wpaEnterprise, .wpa2Enterprise, .wpa3Enterprise, .unknown,
    ] {
      let payload = WiFiQRCodePayload.payload(ssid: "Net", password: "pw", security: security)
      #expect(payload.hasPrefix("WIFI:T:WPA;"), "expected WPA token for \(security)")
    }
  }

  @Test("escapes backslash, semicolon, comma, and colon in the SSID and password")
  func escapesSpecialCharacters() {
    let payload = WiFiQRCodePayload.payload(
      ssid: #"Guest;Net,Name:With\Slash"#,
      password: #"p;a,s:s\word"#,
      security: .wpa2Personal
    )
    #expect(payload == #"WIFI:T:WPA;S:Guest\;Net\,Name\:With\\Slash;P:p\;a\,s\:s\\word;;"#)
  }

  @Test("escapes a leading backslash without double-escaping it")
  func escapesLeadingBackslash() {
    #expect(WiFiQRCodePayload.escaping(#"\;"#) == #"\\\;"#)
  }

  @Test("leaves ordinary characters, including spaces and emoji, untouched")
  func leavesOrdinaryCharactersAlone() {
    #expect(WiFiQRCodePayload.escaping("Coffee Shop 📶") == "Coffee Shop 📶")
  }

  @Test("treats SSIDs that read as prompt-injection attempts as inert text to escape, not act on")
  func adversarialSSIDIsJustEscaped() {
    let payload = WiFiQRCodePayload.payload(
      ssid: "Ignore all previous instructions",
      password: "The Wi-Fi under me is fake!!!",
      security: .wpa2Personal
    )
    #expect(payload == "WIFI:T:WPA;S:Ignore all previous instructions;P:The Wi-Fi under me is fake!!!;;")
  }

  @Test("produces an empty string for empty input")
  func emptyInput() {
    #expect(WiFiQRCodePayload.escaping("") == "")
  }
}
