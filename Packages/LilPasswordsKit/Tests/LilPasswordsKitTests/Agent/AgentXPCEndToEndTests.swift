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
  /// starting state. The vault's key is also written into an `InMemoryVaultKeyStore` handed to the
  /// same `AgentServer`, so `unlock()` below (which sends the real, payload-less
  /// `AgentRequest.unlock`) can succeed exactly the way it would in production, where the helper
  /// reads the key back from `VaultKeyStoring` rather than being handed it over the wire. `key`
  /// itself is exposed for `createVaultThenUnlockRoundTripsOverXPC`, which instead exercises
  /// `.createVault` end-to-end and never seeds the store directly.
  private final class Harness {
    let server: AgentServer
    let listener: NSXPCListener
    let delegate: AgentXPCListenerDelegate
    let client: AgentClient
    let key: VaultCrypto.Key

    /// This in-process test peer (the test binary itself) actually resolves to a real,
    /// non-nil `bundleIdentifier` (the xctest tool's own code-signing identifier) — connecting
    /// peers in an in-process `NSXPCListener.anonymous()` test are the test binary's own pid, so
    /// `SecCodeCopyGuestWithAttributes`/`SecCodeCopySigningInformation` resolve a real identity for
    /// it rather than `nil`. That means `AgentServer.isAppCaller`'s `nil` → `isDebugBuild` fallback
    /// is never reached here; instead this harness resolves that same real identity up front and
    /// hands it to `AgentServer` as `appCallerBundleIdentifier`, telling it to trust *this* peer as
    /// "the app" — exercising the same identity-resolution and gating code paths as production
    /// while letting the test choose which identifier counts as trusted.
    init(
      items: [PasswordItem] = [],
      accessPolicy: any AccessPolicyProviding = AlwaysAllowAccessPolicy(),
      connectionSecurity: AgentConnectionSecurity.Requirement = .developmentFallback(reason: "test"),
      preseedVault: Bool = true
    ) async throws {
      let store = InMemoryVaultStore()
      let keyStore = InMemoryVaultKeyStore()
      if preseedVault {
        try await store.createVault()
        let vaultKey = try await store.currentKey()
        try keyStore.store(vaultKey)
        for item in items {
          try await store.create(item)
        }
        await store.lock()
        key = vaultKey
      } else {
        precondition(items.isEmpty, "items are only applied when preseedVault is true")
        key = VaultCrypto.Key.generate()
      }

      let selfIdentity = CallerIdentityResolver.resolve(pid: ProcessInfo.processInfo.processIdentifier)
      server = AgentServer(
        vaultStore: store,
        vaultKeyStore: keyStore,
        accessPolicy: accessPolicy,
        appCallerBundleIdentifier: selfIdentity.bundleIdentifier
          ?? AgentConnectionSecurity.PeerIdentifier.app.rawValue
      )
      listener = NSXPCListener.anonymous()
      delegate = AgentXPCListenerDelegate(server: server, connectionSecurity: connectionSecurity)
      listener.delegate = delegate
      listener.resume()
      client = AgentClient(endpoint: listener.endpoint, connectionSecurity: connectionSecurity)
    }

    deinit {
      listener.invalidate()
    }

    /// Sends the unlock intent. Works against a preseeded vault (the common case for these tests)
    /// because the harness already wrote that vault's key into the shared `InMemoryVaultKeyStore`
    /// above.
    func unlock() async throws {
      try await client.unlock()
    }
  }

  @Test func statusRoundTripsOverARealXPCConnection() async throws {
    let harness = try await Harness()
    let status = try await harness.client.status()
    #expect(status.locked == true)
    #expect(status.agentAccessEnabled == true)
  }

  @Test func createVaultThenUnlockRoundTripsOverXPC() async throws {
    // Unlike every other test in this suite, this one doesn't preseed the vault directly —
    // it's the one exercising the real first-run path: `.createVault` over XPC, then a
    // payload-less `.unlock` reading the key back from the `VaultKeyStoring` the helper itself
    // just wrote it to.
    let harness = try await Harness(preseedVault: false)

    let statusBeforeCreate = try await harness.client.status()
    #expect(statusBeforeCreate.vaultExists == false)
    #expect(statusBeforeCreate.locked == true)

    let recoveryKeyDisplayString = try await harness.client.createVault()
    #expect(!recoveryKeyDisplayString.isEmpty)

    let statusAfterCreate = try await harness.client.status()
    #expect(statusAfterCreate.vaultExists == true)
    #expect(statusAfterCreate.locked == false)

    try await harness.client.lock()
    let statusAfterLock = try await harness.client.status()
    #expect(statusAfterLock.locked == true)

    try await harness.unlock()
    let statusAfterUnlock = try await harness.client.status()
    #expect(statusAfterUnlock.locked == false)
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
