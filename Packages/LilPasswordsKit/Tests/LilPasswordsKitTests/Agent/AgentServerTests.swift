import Foundation
import Testing

@testable import LilPasswordsKit

/// A togglable `AccessPolicyProviding` for tests that need to flip "agent access enabled" mid-test.
private actor ToggleableAccessPolicy: AccessPolicyProviding {
  private var enabled: Bool
  init(enabled: Bool = true) { self.enabled = enabled }
  func set(_ enabled: Bool) { self.enabled = enabled }
  func isAgentAccessEnabled() async -> Bool { enabled }
}

/// Records every `AccessEvent` it's given, so tests can assert on what did (and didn't) get logged.
private actor RecordingAccessLog: AccessLogging {
  private(set) var events: [AccessEvent] = []
  func record(_ event: AccessEvent) async { events.append(event) }
}

private let testCaller = CallerIdentity(pid: 1, processPath: "/usr/bin/test", parentProcessName: "xctest")

/// A caller whose code-signing identifier really is the app's — used to test `.createVault`/
/// `.unlock` gating without depending on `AgentConnectionSecurity.isDebugBuild`'s fallback (which
/// `testCaller`, with no `bundleIdentifier` at all, relies on instead).
private let appCaller = CallerIdentity(
  pid: 2,
  processPath: "/Applications/lil passwords.app/Contents/MacOS/lil passwords",
  parentProcessName: nil,
  bundleIdentifier: AgentConnectionSecurity.PeerIdentifier.app.rawValue
)

/// A caller identified as `lilpass`, not the app — `.createVault`/`.unlock` must reject this caller
/// even though it's a legitimate, recognized peer of the *connection* itself
/// (`AgentConnectionSecurity` accepts both `.app` and `.cli`); only the app performs the
/// `LAContext` authentication those two requests presuppose.
private let cliCaller = CallerIdentity(
  pid: 3,
  processPath: "/usr/local/bin/lilpass",
  parentProcessName: nil,
  bundleIdentifier: AgentConnectionSecurity.PeerIdentifier.cli.rawValue
)

@Suite struct AgentServerTests {
  private func makeItem(title: String = "GitHub") -> PasswordItem {
    // Pinned to whole-second precision: `AgentWireCoding`'s `.iso8601` date strategy drops
    // sub-second precision, so a default `Date()` timestamp would fail equality after any
    // Codable round-trip through the wire protocol.
    PasswordItem(
      title: title,
      usernames: ["octocat"],
      password: "hunter2",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  /// Builds an `InMemoryVaultStore` with a freshly created vault (so it has a real key-check
  /// canary to unlock against), seeds it with `items`, then locks it back up — matching a real
  /// helper's starting state (locked) — and returns the `AgentServer` built on top of it plus the
  /// real `VaultCrypto.Key` a test needs to unlock with. Real `VaultStoring.open(with:)` requires
  /// the actual key `createVault()` generated; there is no "any bytes unlock it" placeholder
  /// behavior to lean on anymore (see the now-merged 851-2404).
  ///
  /// The vault is seeded directly on `store` (rather than through `AgentServer.handle(.createVault)`)
  /// so most tests here don't have to care about the app-caller gate at all — but the resulting key
  /// is still written to `keyStore`, so `.unlock` (now payload-less; the helper reads the key back
  /// from `vaultKeyStore` itself) behaves exactly as it would after a real `.createVault` round
  /// trip. See `createVaultStoresTheKeySoASubsequentUnlockSucceeds` for a test that exercises the
  /// real `.createVault` → `.unlock` path end-to-end instead.
  private func makeServer(
    accessPolicy: any AccessPolicyProviding = AlwaysAllowAccessPolicy(),
    accessLog: any AccessLogging = NoOpAccessLog(),
    items: [PasswordItem] = []
  ) async throws -> (server: AgentServer, key: VaultCrypto.Key) {
    let store = InMemoryVaultStore()
    try await store.createVault()
    let key = try await store.currentKey()
    for item in items {
      try await store.create(item)
    }
    await store.lock()
    let keyStore = InMemoryVaultKeyStore()
    try keyStore.store(key)
    let server = AgentServer(
      vaultStore: store,
      vaultKeyStore: keyStore,
      accessPolicy: accessPolicy,
      accessLog: accessLog
    )
    return (server, key)
  }

  private func send(_ request: AgentRequest, to server: AgentServer, caller: CallerIdentity = testCaller) async
    -> AgentOutcome
  {
    await server.handle(AgentRequestEnvelope(request: request), caller: caller).outcome
  }

  @Test func statusReportsLockedUntilUnlockedAndAgentAccessEnabled() async throws {
    let (server, _) = try await makeServer()

    guard case .success(.status(let before)) = await send(.status, to: server) else {
      Issue.record("expected .status")
      return
    }
    #expect(before.locked == true)
    #expect(before.agentAccessEnabled == true)

    _ = await send(.unlock, to: server)

    guard case .success(.status(let after)) = await send(.status, to: server) else {
      Issue.record("expected .status")
      return
    }
    #expect(after.locked == false)
  }

  @Test func lockClearsTheVaultStoreEvenIfNeverUnlocked() async throws {
    let (server, _) = try await makeServer()
    guard case .success(.locked) = await send(.lock, to: server) else {
      Issue.record("expected .locked")
      return
    }
    guard case .success(.status(let status)) = await send(.status, to: server) else {
      Issue.record("expected .status")
      return
    }
    #expect(status.locked == true)
  }

  @Test func vaultOperationsFailWithLockedBeforeUnlock() async throws {
    let (server, _) = try await makeServer()
    guard case .failure(.locked) = await send(.list, to: server) else {
      Issue.record("expected .failure(.locked)")
      return
    }
  }

  @Test func unsupportedProtocolVersionIsRejectedBeforeTouchingTheStore() async throws {
    let (server, _) = try await makeServer()
    let envelope = AgentRequestEnvelope(request: .status, version: AgentProtocolVersion.current + 1)
    let reply = await server.handle(envelope, caller: testCaller)

    guard case .failure(.unsupportedProtocolVersion(let requested, let supported)) = reply.outcome else {
      Issue.record("expected .unsupportedProtocolVersion, got \(reply.outcome)")
      return
    }
    #expect(requested == AgentProtocolVersion.current + 1)
    #expect(supported == AgentProtocolVersion.current)
  }

  @Test func listSearchAndCrudWorkOnceUnlocked() async throws {
    let item = makeItem()
    let (server, _) = try await makeServer(items: [item])
    _ = await send(.unlock, to: server)

    guard case .success(.items(let listed)) = await send(.list, to: server) else {
      Issue.record("expected .items")
      return
    }
    #expect(listed.map(\.id) == [item.id])

    guard case .success(.items(let searched)) = await send(.search(query: "octocat"), to: server) else {
      Issue.record("expected .items")
      return
    }
    #expect(searched.map(\.id) == [item.id])

    var updatedItem = item
    updatedItem.title = "GitHub Enterprise"
    guard case .success(.updated(let updated)) = await send(.updateItem(updatedItem), to: server) else {
      Issue.record("expected .updated")
      return
    }
    #expect(updated.title == "GitHub Enterprise")

    let newItem = makeItem(title: "Mail")
    guard case .success(.created(let created)) = await send(.createItem(newItem), to: server) else {
      Issue.record("expected .created")
      return
    }
    #expect(created.id == newItem.id)

    guard case .success(.deleted) = await send(.deleteItem(.id(newItem.id)), to: server) else {
      Issue.record("expected .deleted")
      return
    }
  }

  @Test func getItemByIdFailsWithNotFoundForAnUnknownId() async throws {
    let (server, _) = try await makeServer()
    _ = await send(.unlock, to: server)

    guard case .failure(.notFound) = await send(.getItem(.id(UUID())), to: server) else {
      Issue.record("expected .failure(.notFound)")
      return
    }
  }

  @Test func getItemByQueryFailsWithAmbiguousForMultipleMatches() async throws {
    let a = makeItem(title: "GitHub Work")
    let b = makeItem(title: "GitHub Personal")
    let (server, _) = try await makeServer(items: [a, b])
    _ = await send(.unlock, to: server)

    guard case .failure(.ambiguous) = await send(.getItem(.query("github")), to: server) else {
      Issue.record("expected .failure(.ambiguous)")
      return
    }
  }

  @Test func getItemByQueryFailsWithNotFoundForZeroMatches() async throws {
    let (server, _) = try await makeServer(items: [makeItem()])
    _ = await send(.unlock, to: server)

    guard case .failure(.notFound) = await send(.getItem(.query("nonexistent")), to: server) else {
      Issue.record("expected .failure(.notFound)")
      return
    }
  }

  @Test func deleteItemByQueryResolvesThenDeletes() async throws {
    let item = makeItem()
    let (server, _) = try await makeServer(items: [item])
    _ = await send(.unlock, to: server)

    guard case .success(.deleted) = await send(.deleteItem(.query("GitHub")), to: server) else {
      Issue.record("expected .deleted")
      return
    }
    guard case .failure(.notFound) = await send(.getItem(.id(item.id)), to: server) else {
      Issue.record("expected item to be gone")
      return
    }
  }

  @Test func generatePasswordProducesANonEmptyPasswordOnceUnlocked() async throws {
    let (server, _) = try await makeServer()
    _ = await send(.unlock, to: server)

    guard case .success(.generatedPassword(let password)) = await send(.generatePassword(.appleStrong), to: server)
    else {
      Issue.record("expected .generatedPassword")
      return
    }
    #expect(!password.isEmpty)
  }

  @Test func totpCodeReturnsACodeForAnItemWithATOTPURI() async throws {
    let item = PasswordItem(
      title: "GitHub",
      totpURI: "otpauth://totp/GitHub:octocat?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"
    )
    let (server, _) = try await makeServer(items: [item])
    _ = await send(.unlock, to: server)

    guard case .success(.totpCode(let result)) = await send(.totpCode(.id(item.id)), to: server) else {
      Issue.record("expected .totpCode")
      return
    }
    #expect(result.code.count == 6)
  }

  @Test func totpCodeFailsWithInternalErrorForAnItemWithNoTOTPURI() async throws {
    let item = makeItem()
    let (server, _) = try await makeServer(items: [item])
    _ = await send(.unlock, to: server)

    guard case .failure(.internal) = await send(.totpCode(.id(item.id)), to: server) else {
      Issue.record("expected .failure(.internal)")
      return
    }
  }

  @Test func agentAccessDisabledTakesPrecedenceOverAnUnlockedStore() async throws {
    let policy = ToggleableAccessPolicy(enabled: false)
    let (server, _) = try await makeServer(accessPolicy: policy, items: [makeItem()])
    _ = await send(.unlock, to: server)

    guard case .failure(.agentAccessDisabled) = await send(.list, to: server) else {
      Issue.record("expected .failure(.agentAccessDisabled)")
      return
    }
  }

  @Test func statusReflectsAgentAccessPolicyRegardlessOfLockState() async throws {
    let policy = ToggleableAccessPolicy(enabled: false)
    let (server, _) = try await makeServer(accessPolicy: policy)

    guard case .success(.status(let status)) = await send(.status, to: server) else {
      Issue.record("expected .status")
      return
    }
    #expect(status.agentAccessEnabled == false)
  }

  @Test func lockLifecycleRequestsAreNeverWrittenToTheAccessLog() async throws {
    let log = RecordingAccessLog()
    let (server, _) = try await makeServer(accessLog: log)

    _ = await send(.status, to: server)
    _ = await send(.unlock, to: server)
    _ = await send(.lock, to: server)

    let events = await log.events
    #expect(events.isEmpty)
  }

  @Test func vaultOperationsAreLoggedWithTheCallerIdentityRegardlessOfOutcome() async throws {
    let log = RecordingAccessLog()
    let item = makeItem()
    let (server, _) = try await makeServer(accessLog: log, items: [item])
    _ = await send(.unlock, to: server)

    _ = await send(.list, to: server, caller: testCaller)
    _ = await send(.getItem(.id(UUID())), to: server, caller: testCaller)

    let events = await log.events
    #expect(events.count == 2)
    #expect(events[0].succeeded == true)
    #expect(events[1].succeeded == false)
    #expect(events.allSatisfy { $0.caller == testCaller })
  }

  @Test func unlockFailurePropagatesAsATypedAgentError() async throws {
    // A key is stored (so `.unlock` gets past the "no key at all" check), but no vault was ever
    // created at this store: `open(with:)` has no `meta` row to check the key against, so it
    // throws `VaultStoreError.vaultNotFound` — this should surface as a typed `AgentError.internal`,
    // not crash or hang the handler.
    let store = InMemoryVaultStore()
    let keyStore = InMemoryVaultKeyStore()
    try keyStore.store(VaultCrypto.Key.generate())
    let server = AgentServer(vaultStore: store, vaultKeyStore: keyStore)

    guard case .failure(.internal) = await send(.unlock, to: server) else {
      Issue.record("expected .failure(.internal)")
      return
    }
  }

  @Test func unlockFailsWithInternalErrorWhenNoKeyHasEverBeenStored() async throws {
    // The default `AgentServer.init` `vaultKeyStore` (an empty `InMemoryVaultKeyStore`) has never
    // had anything stored in it — the "helper restarted with a stale/missing Keychain item" case,
    // distinct from "the key exists but doesn't match this database" above.
    let store = InMemoryVaultStore()
    let server = AgentServer(vaultStore: store)

    guard case .failure(.internal) = await send(.unlock, to: server) else {
      Issue.record("expected .failure(.internal)")
      return
    }
  }

  @Test func createVaultIsRestrictedToTheAppEvenForARecognizedCliCaller() async throws {
    let store = InMemoryVaultStore()
    let server = AgentServer(vaultStore: store)

    guard case .failure(.callerNotAuthorized) = await send(.createVault, to: server, caller: cliCaller) else {
      Issue.record("expected .failure(.callerNotAuthorized)")
      return
    }

    // Confirm the rejection didn't quietly leave a vault behind anyway.
    guard case .success(.status(let status)) = await send(.status, to: server) else {
      Issue.record("expected .status")
      return
    }
    #expect(status.vaultExists == false)
  }

  @Test func unlockIsRestrictedToTheAppEvenForARecognizedCliCaller() async throws {
    let (server, _) = try await makeServer()

    guard case .failure(.callerNotAuthorized) = await send(.unlock, to: server, caller: cliCaller) else {
      Issue.record("expected .failure(.callerNotAuthorized)")
      return
    }
  }

  @Test func createVaultStoresTheKeySoASubsequentUnlockSucceeds() async throws {
    let store = InMemoryVaultStore()
    let server = AgentServer(vaultStore: store)

    guard
      case .success(.vaultCreated(let recoveryKeyDisplayString)) =
        await send(.createVault, to: server, caller: appCaller)
    else {
      Issue.record("expected .vaultCreated")
      return
    }
    #expect(!recoveryKeyDisplayString.isEmpty)

    await store.lock()
    guard case .success(.unlocked) = await send(.unlock, to: server, caller: appCaller) else {
      Issue.record("expected .unlocked")
      return
    }
  }

  @Test func createVaultFailsWithVaultAlreadyExistsAsAnInternalErrorOnASecondCall() async throws {
    let (server, _) = try await makeServer()

    guard case .failure(.internal) = await send(.createVault, to: server, caller: appCaller) else {
      Issue.record("expected .failure(.internal)")
      return
    }
  }

  @Test func statusReportsWhetherAVaultExistsIndependentlyOfLockState() async throws {
    let store = InMemoryVaultStore()
    let server = AgentServer(vaultStore: store)

    guard case .success(.status(let beforeCreate)) = await send(.status, to: server) else {
      Issue.record("expected .status")
      return
    }
    #expect(beforeCreate.vaultExists == false)
    #expect(beforeCreate.locked == true)

    _ = await send(.createVault, to: server, caller: appCaller)

    guard case .success(.status(let afterCreate)) = await send(.status, to: server) else {
      Issue.record("expected .status")
      return
    }
    #expect(afterCreate.vaultExists == true)
    #expect(afterCreate.locked == false)

    await store.lock()
    guard case .success(.status(let afterLock)) = await send(.status, to: server) else {
      Issue.record("expected .status")
      return
    }
    #expect(afterLock.vaultExists == true)
    #expect(afterLock.locked == true)
  }
}
