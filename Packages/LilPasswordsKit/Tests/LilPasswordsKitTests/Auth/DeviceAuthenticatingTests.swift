import Foundation
import Testing

@testable import LilPasswordsKit

/// A fake ``DeviceAuthenticating`` for tests that need to drive an authentication-gated flow
/// (e.g. export) without a real Touch ID/Face ID prompt, which isn't available in a headless CI
/// runner and shouldn't be exercised by automated tests regardless (it's system UI, not this
/// package's code).
final class FakeDeviceAuthenticator: DeviceAuthenticating, @unchecked Sendable {
  enum FakeError: Error, Equatable {
    case denied
  }

  private let lock = NSLock()
  private var _shouldSucceed: Bool
  private(set) var reasonsPassed: [String] = []

  init(shouldSucceed: Bool = true) {
    _shouldSucceed = shouldSucceed
  }

  var shouldSucceed: Bool {
    get { lock.withLock { _shouldSucceed } }
    set { lock.withLock { _shouldSucceed = newValue } }
  }

  func authenticate(reason: String) async throws {
    lock.withLock { reasonsPassed.append(reason) }
    guard shouldSucceed else { throw FakeError.denied }
  }
}

@Suite struct DeviceAuthenticatingTests {
  @Test func fakeAuthenticatorSucceedsAndRecordsTheReason() async throws {
    let authenticator = FakeDeviceAuthenticator(shouldSucceed: true)
    try await authenticator.authenticate(reason: "Export your passwords")
    #expect(authenticator.reasonsPassed == ["Export your passwords"])
  }

  @Test func fakeAuthenticatorCanBeMadeToFail() async {
    let authenticator = FakeDeviceAuthenticator(shouldSucceed: false)
    await #expect(throws: FakeDeviceAuthenticator.FakeError.denied) {
      try await authenticator.authenticate(reason: "Export your passwords")
    }
  }

  @Test func laContextAuthenticatorConformsToTheProtocolAndIsInjectable() {
    // Doesn't call `authenticate` — that would drive a real, system-owned Touch ID/Face ID/
    // password prompt, which has no place running unattended in `make test`/CI. This only checks
    // that the real implementation is a drop-in `DeviceAuthenticating`, the same way callers
    // (e.g. the export flow) depend on it.
    let authenticator: any DeviceAuthenticating = LAContextDeviceAuthenticator()
    #expect(authenticator is LAContextDeviceAuthenticator)
  }
}
