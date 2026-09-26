import Foundation
import Testing

@testable import LilPasswordsKit

/// End-to-end tests that go through a real `NSXPCListener`/`NSXPCConnection` pair (in-process, via
/// `NSXPCListener.anonymous()`) rather than calling `AgentServer` directly, so they exercise the
/// same wire path (`AgentXPCProtocol`, `AgentWireCoding`, `AgentXPCListenerDelegate`,
/// `AgentExportedObject`) that the real Mach service and `AgentClient` use in production.
@Suite struct AgentXPCEndToEndTests {
  /// Keeps every piece created for one test alive for the test's duration: `NSXPCListener` holds
  /// its delegate `weak`, and the listener itself must stay alive as long as the connection does.
  ///
  /// Builds a real `InMemoryVaultStore` with a real vault (`createVault()`), seeds it with
  /// `items`, then locks it back up before handing it to `AgentServer` — matching a real helper's
  /// starting state. `key` is the actual `VaultCrypto.Key` that vault was created with, so tests
  /// that need to unlock (`unlock()` below) do so with the one key `open(with:)` will actually
  /// accept — there is no "any bytes unlock it" placeholder behavior to lean on since the
  /// now-merged 851-2404.
  private final class Harness {
    let server: AgentServer
    let listener: NSXPCListener
    let delegate: AgentXPCListenerDelegate
    let client: AgentClient
    let key: VaultCrypto.Key

    init(
      items: [PasswordItem] = [],
      accessPolicy: any AccessPolicyProviding = AlwaysAllowAccessPolicy(),
      connectionSecurity: AgentConnectionSecurity.Requirement = .developmentFallback(reason: "test")
    ) async throws {
      let store = InMemoryVaultStore()
      try await store.createVault()
      key = try await store.currentKey()
      for item in items {
        try await store.create(item)
      }
      await store.lock()

      server = AgentServer(vaultStore: store, accessPolicy: accessPolicy)
      listener = NSXPCListener.anonymous()
      delegate = AgentXPCListenerDelegate(server: server, connectionSecurity: connectionSecurity)
      listener.delegate = delegate
      listener.resume()
      client = AgentClient(endpoint: listener.endpoint, connectionSecurity: connectionSecurity)
    }

    deinit {
      listener.invalidate()
    }

    /// Unlocks with the real key this harness's vault was created under.
    func unlock() async throws {
      try await client.unlock(sessionKey: key.rawData, keyId: key.id)
    }
  }

  @Test func statusRoundTripsOverARealXPCConnection() async throws {
    let harness = try await Harness()
    let status = try await harness.client.status()
    #expect(status.locked == true)
    #expect(status.agentAccessEnabled == true)
  }

  @Test func unlockListCreateUpdateDeleteRoundTripOverXPC() async throws {
    // `AgentWireCoding` encodes dates as ISO 8601 without fractional seconds, so a `PasswordItem`
    // built with the default `Date()` timestamps wouldn't round-trip back to an `==` value once it
    // crosses the wire — pin `createdAt`/`modifiedAt` to a whole second instead.
    let wholeSecond = Date(timeIntervalSince1970: 1_700_000_000)
    let item = PasswordItem(
      title: "GitHub",
      usernames: ["octocat"],
      password: "hunter2",
      createdAt: wholeSecond,
      modifiedAt: wholeSecond
    )
    let harness = try await Harness(items: [item])

    try await harness.unlock()

    let listed = try await harness.client.list()
    #expect(listed.map(\.id) == [item.id])

    let fetched = try await harness.client.item(.id(item.id))
    #expect(fetched == item)

    var updatedItem = item
    updatedItem.title = "GitHub Enterprise"
    let updated = try await harness.client.update(updatedItem)
    #expect(updated.title == "GitHub Enterprise")

    let created = try await harness.client.create(PasswordItem(title: "Mail"))
    let searched = try await harness.client.search("Mail")
    #expect(searched.map(\.id) == [created.id])

    try await harness.client.delete(.id(created.id))
    let afterDelete = try await harness.client.list()
    #expect(afterDelete.map(\.id) == [item.id])

    try await harness.client.lock()
    let status = try await harness.client.status()
    #expect(status.locked == true)
  }

  @Test func vaultOperationsBeforeUnlockFailWithTypedLockedErrorOverXPC() async throws {
    let harness = try await Harness()

    do {
      _ = try await harness.client.list()
      Issue.record("expected .list to throw")
    } catch let AgentClient.RequestError.remote(error) {
      #expect(error == .locked)
    }
  }

  @Test func generatePasswordAndTotpCodeRoundTripOverXPC() async throws {
    let item = PasswordItem(
      title: "GitHub",
      totpURI: "otpauth://totp/GitHub:octocat?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"
    )
    let harness = try await Harness(items: [item])
    try await harness.unlock()

    let password = try await harness.client.generatePassword()
    #expect(!password.isEmpty)

    let totp = try await harness.client.totpCode(.id(item.id))
    #expect(totp.code.count == 6)
  }

  @Test func agentAccessDisabledSurfacesAsATypedErrorOverXPC() async throws {
    let harness = try await Harness(accessPolicy: AlwaysDenyAccessPolicy())

    // Access-disabled takes precedence over lock state (see `AgentServerTests
    // .agentAccessDisabledTakesPrecedenceOverAnUnlockedStore`), so this doesn't even need to
    // unlock to demonstrate the typed error — but does so anyway, over the real XPC connection, to
    // prove the precedence holds all the way through the wire, not just inside `AgentServer`.
    try await harness.unlock()

    do {
      _ = try await harness.client.list()
      Issue.record("expected .list to throw")
    } catch let AgentClient.RequestError.remote(error) {
      #expect(error == .agentAccessDisabled)
    }
  }

  @Test func aRejectAllRequirementRefusesToEvenAttemptTheConnection() async throws {
    // The fail-closed case (`AgentConnectionSecurity.Requirement.rejectAll`): unlike
    // `.developmentFallback`, `AgentClient` doesn't even create an `NSXPCConnection` — it throws
    // immediately, symmetrically with `AgentXPCListenerDelegate` refusing to accept one.
    let harness = try await Harness(connectionSecurity: .rejectAll(reason: "test"))

    do {
      _ = try await harness.client.status()
      Issue.record("expected the connection attempt to be refused")
    } catch let AgentClient.RequestError.connection(error) {
      guard case .invalidated = error else {
        Issue.record("expected .invalidated, got \(error)")
        return
      }
    }
  }

  @Test func aConnectionThatFailsAFabricatedCodeSigningRequirementIsRejected() async throws {
    // `.enforce` with a syntactically valid but never-satisfiable requirement (nothing running in
    // this test process can present a certificate at all, let alone one from this bogus team) is
    // exactly what a real attacker impersonating `LilPasswordsAgent`'s peer would fail against —
    // this shows connection validation actually rejects rather than merely existing unused.
    let bogusRequirement = AgentConnectionSecurity.Requirement.enforce(
      "anchor apple generic and certificate leaf[subject.OU] = \"BOGUSTEAMID\" and identifier \"com.example.nope\""
    )
    let harness = try await Harness(connectionSecurity: bogusRequirement)

    do {
      _ = try await harness.client.status()
      Issue.record("expected the connection to be rejected")
    } catch let AgentClient.RequestError.connection(error) {
      guard case .invalidated = error else {
        Issue.record("expected .invalidated, got \(error)")
        return
      }
    }
  }
}
