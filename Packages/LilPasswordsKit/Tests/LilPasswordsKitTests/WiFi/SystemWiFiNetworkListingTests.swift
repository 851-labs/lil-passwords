import Foundation
import Testing

@testable import LilPasswordsKit

private struct FakeWiFiSystemCommandRunner: WiFiSystemCommandRunning {
  var outputs: [String: String] = [:]
  var failures: Set<String> = []

  private func key(_ executable: String, _ arguments: [String]) -> String {
    ([executable] + arguments).joined(separator: " ")
  }

  func run(executable: String, arguments: [String]) throws -> String {
    let key = key(executable, arguments)
    if failures.contains(key) {
      throw WiFiSystemCommandFailure(exitCode: 1, standardError: "boom")
    }
    return outputs[key] ?? ""
  }
}

@Suite("SystemWiFiNetworkListing")
struct SystemWiFiNetworkListingTests {
  @Test("merges preferred networks with current-network security info, badging the current one")
  func mergesKnownNetworksWithCurrentNetworkInfo() {
    let runner = FakeWiFiSystemCommandRunner(outputs: [
      "/usr/sbin/networksetup -listallhardwareports": "Hardware Port: Wi-Fi\nDevice: en0\n",
      "/usr/sbin/networksetup -listpreferredwirelessnetworks en0": "Preferred networks on en0:\n\tHomeNet\n\tCafeNet\n",
      "/usr/sbin/system_profiler SPAirPortDataType -json": """
      {
        "SPAirPortDataType": [
          {
            "spairport_airport_interfaces": [
              {
                "_name": "en0",
                "spairport_current_network_information": {
                  "_name": "HomeNet",
                  "spairport_security_mode": "spairport_security_mode_wpa2_personal"
                }
              }
            ]
          }
        ]
      }
      """,
    ])
    let networks = SystemWiFiNetworkListing(runner: runner).knownNetworks()
    #expect(networks.count == 2)
    #expect(networks[0] == WiFiNetwork(ssid: "HomeNet", isCurrentNetwork: true, security: .wpa2Personal))
    #expect(networks[1] == WiFiNetwork(ssid: "CafeNet", isCurrentNetwork: false, security: nil))
  }

  @Test("returns an empty list when there's no Wi-Fi hardware port")
  func noWiFiHardware() {
    let runner = FakeWiFiSystemCommandRunner(outputs: [
      "/usr/sbin/networksetup -listallhardwareports": "Hardware Port: Ethernet\nDevice: en1\n"
    ])
    #expect(SystemWiFiNetworkListing(runner: runner).knownNetworks().isEmpty)
  }

  @Test("returns an empty list, not an error, when the underlying commands fail")
  func commandFailuresYieldEmptyList() {
    let runner = FakeWiFiSystemCommandRunner(failures: ["/usr/sbin/networksetup -listallhardwareports"])
    #expect(SystemWiFiNetworkListing(runner: runner).knownNetworks().isEmpty)
  }
}

@Suite("SystemWiFiPasswordRevealing")
struct SystemWiFiPasswordRevealingTests {
  @Test("returns the trimmed password on success")
  func successfulReveal() throws {
    let runner = FakeWiFiSystemCommandRunner(outputs: [
      "/usr/bin/security find-generic-password -D AirPort network password -s AirPort -a HomeNet -w /Library/Keychains/System.keychain":
        "sup3rSecret\n"
    ])
    let password = try SystemWiFiPasswordRevealing(runner: runner).password(forSSID: "HomeNet")
    #expect(password == "sup3rSecret")
  }

  @Test("maps exit code 44 to notFound")
  func notFoundMapsFromExitCode44() {
    struct NotFoundRunner: WiFiSystemCommandRunning {
      func run(executable: String, arguments: [String]) throws -> String {
        throw WiFiSystemCommandFailure(
          exitCode: 44,
          standardError:
            "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain."
        )
      }
    }
    #expect(throws: WiFiPasswordRevealError.notFound) {
      try SystemWiFiPasswordRevealing(runner: NotFoundRunner()).password(forSSID: "Nope")
    }
  }

  @Test("maps any other failure to .failed carrying security's stderr text")
  func otherFailureMapsToFailed() {
    struct DeniedRunner: WiFiSystemCommandRunning {
      func run(executable: String, arguments: [String]) throws -> String {
        throw WiFiSystemCommandFailure(exitCode: 51, standardError: "security: Authorization failed.")
      }
    }
    #expect(throws: WiFiPasswordRevealError.failed("security: Authorization failed.")) {
      try SystemWiFiPasswordRevealing(runner: DeniedRunner()).password(forSSID: "HomeNet")
    }
  }
}
