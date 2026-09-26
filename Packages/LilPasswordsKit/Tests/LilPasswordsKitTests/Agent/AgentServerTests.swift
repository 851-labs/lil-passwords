import Foundation
import Testing

@testable import LilPasswordsKit

/// A togglable `AccessPolicyProviding` for tests that need to flip "agent access enabled" mid-test,
/// independently of the ``AgentSettings/agentWriteAccessEnabled`` toggle — which the tests below
/// set directly on an `InMemoryAgentSettingsStore` instead, mirroring how `AgentServer` itself
/// reads the two independently (`accessPolicy` for read access, `agentSettingsStore` for write
/// access — see `AgentServer.requireWriteAccess(for:)`).
private actor ToggleableAccessPolicy: AccessPolicyProviding {
  private var enabled: Bool
  init(enabled: Bool = true) {
    self.enabled = enabled
  }
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

/// 851-2441: the AutoFill credential provider extension's verified connection — a third, much
/// narrower peer than either ``appCaller`` or ``cliCaller``. See
/// `AgentServer.isRequestPermitted(_:for:)` for exactly what it can and can't reach.
private let autoFillCaller = CallerIdentity(
  pid: 4,
  processPath: "/Applications/lil passwords.app/Contents/PlugIns/AutoFill.appex/Contents/MacOS/AutoFill",
  parentProcessName: nil,
  bundleIdentifier: AgentConnectionSecurity.PeerIdentifier.autoFill.rawValue
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
    items: [PasswordItem] = [],
    agentSettingsStore: any AgentSettingsStoring = InMemoryAgentSettingsStore(),
    approvalCenter: ApprovalCenter = ApprovalCenter(),
    approvalTimeout: Duration = .seconds(60)
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
      accessLog: accessLog,
      agentSettingsStore: agentSettingsStore,
      approvalCenter: approvalCenter,
      approvalTimeout: approvalTimeout
    )
    return (server, key)
  }

  /// An `InMemoryAgentSettingsStore` pre-seeded with agent access on, write access on (so
  /// scope/approval tests below aren't incidentally blocked by 851-2433's separate write toggle),
  /// and the given 851-2445 `accessScope`/allowlist.
  private func scopedSettingsStore(
    accessScope: AgentAccessScope,
    allowedItemIDs: Set<UUID> = [],
    allowedGroups: Set<String> = []
  ) -> InMemoryAgentSettingsStore {
    InMemoryAgentSettingsStore(
      initial: AgentSettings(
        agentAccessEnabled: true,
        keepAgentAccessAvailableWhileMacUnlocked: false,
        agentWriteAccessEnabled: true,
        accessScope: accessScope,
        allowedItemIDs: allowedItemIDs,
        allowedGroups: allowedGroups
      )
    )
  }

  /// An `InMemoryAgentSettingsStore` pre-seeded with just ``AgentSettings/agentWriteAccessEnabled``
  /// set — `agentAccessEnabled`/`keepAgentAccessAvailableWhileMacUnlocked` are irrelevant to the
  /// write-access tests below since `makeServer`'s default `accessPolicy` (`AlwaysAllowAccessPolicy`)
  /// grants read access unconditionally, independent of this store.
  private func writeAccessSettingsStore(writeAccessEnabled: Bool) -> InMemoryAgentSettingsStore {
    InMemoryAgentSettingsStore(
      initial: AgentSettings(
        agentAccessEnabled: true,
        keepAgentAccessAvailableWhileMacUnlocked: false,
        agentWriteAccessEnabled: writeAccessEnabled
      )
    )
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

  // MARK: - Write access (851-2433)

  @Test func writeOperationsAreAllowedForTheAppCallerRegardlessOfWriteAccessToggle() async throws {
    let settingsStore = writeAccessSettingsStore(writeAccessEnabled: false)
    let (server, _) = try await makeServer(agentSettingsStore: settingsStore)
    _ = await send(.unlock, to: server)

    let newItem = makeItem(title: "Mail")
    guard case .success(.created) = await send(.createItem(newItem), to: server, caller: appCaller) else {
      Issue.record("expected the app caller to create an item even with write access off")
      return
    }

    var updated = newItem
    updated.title = "Mail 2"
    guard case .success(.updated(let updatedItem)) = await send(.updateItem(updated), to: server, caller: appCaller)
    else {
      Issue.record("expected the app caller to update an item even with write access off")
      return
    }
    #expect(updatedItem.title == "Mail 2")

    guard case .success(.deleted) = await send(.deleteItem(.id(newItem.id)), to: server, caller: appCaller) else {
      Issue.record("expected the app caller to delete an item even with write access off")
      return
    }
  }

  @Test func writeOperationsAreRejectedForANonAppCallerWhenWriteAccessIsOff() async throws {
    let item = makeItem()
    let settingsStore = writeAccessSettingsStore(writeAccessEnabled: false)
    let (server, _) = try await makeServer(items: [item], agentSettingsStore: settingsStore)
    _ = await send(.unlock, to: server)

    guard
      case .failure(.agentWriteAccessDisabled) =
        await send(.createItem(makeItem(title: "Mail")), to: server, caller: cliCaller)
    else {
      Issue.record("expected .failure(.agentWriteAccessDisabled)")
      return
    }

    var updated = item
    updated.title = "Changed"
    guard case .failure(.agentWriteAccessDisabled) = await send(.updateItem(updated), to: server, caller: cliCaller)
    else {
      Issue.record("expected .failure(.agentWriteAccessDisabled)")
      return
    }

    guard
      case .failure(.agentWriteAccessDisabled) =
        await send(.deleteItem(.id(item.id)), to: server, caller: cliCaller)
    else {
      Issue.record("expected .failure(.agentWriteAccessDisabled)")
      return
    }

    // Confirm none of the rejected calls actually mutated anything.
    guard case .success(.items(let items)) = await send(.list, to: server, caller: cliCaller) else {
      Issue.record("expected .items")
      return
    }
    #expect(items.map(\.title) == [item.title])
  }

  @Test func writeOperationsSucceedForANonAppCallerWhenWriteAccessIsOn() async throws {
    let settingsStore = writeAccessSettingsStore(writeAccessEnabled: true)
    let (server, _) = try await makeServer(agentSettingsStore: settingsStore)
    _ = await send(.unlock, to: server)

    let newItem = makeItem(title: "Mail")
    guard case .success(.created) = await send(.createItem(newItem), to: server, caller: cliCaller) else {
      Issue.record("expected .created")
      return
    }

    var updated = newItem
    updated.title = "Mail 2"
    guard case .success(.updated(let updatedItem)) = await send(.updateItem(updated), to: server, caller: cliCaller)
    else {
      Issue.record("expected .updated")
      return
    }
    #expect(updatedItem.title == "Mail 2")

    guard case .success(.deleted) = await send(.deleteItem(.id(newItem.id)), to: server, caller: cliCaller) else {
      Issue.record("expected .deleted")
      return
    }
  }

  @Test func readOperationsRemainAvailableToANonAppCallerEvenWhenWriteAccessIsOff() async throws {
    let item = makeItem()
    let settingsStore = writeAccessSettingsStore(writeAccessEnabled: false)
    let (server, _) = try await makeServer(items: [item], agentSettingsStore: settingsStore)
    _ = await send(.unlock, to: server)

    guard case .success(.items(let items)) = await send(.list, to: server, caller: cliCaller) else {
      Issue.record("expected .items")
      return
    }
    #expect(items.map(\.id) == [item.id])

    guard case .success(.item(let fetched)) = await send(.getItem(.id(item.id)), to: server, caller: cliCaller)
    else {
      Issue.record("expected .item")
      return
    }
    #expect(fetched.id == item.id)
  }

  @Test func writeOperationsFailWithAgentAccessDisabledRatherThanWriteAccessDisabledWhenReadAccessIsAlsoOff()
    async throws
  {
    // Read access gates every vault operation before `requireWriteAccess` ever runs (see
    // `vaultResponse(for:caller:)`), so a caller should never see `.agentWriteAccessDisabled` while
    // read access itself is off — even if, as here, the agent settings store happens to say write
    // access is "on". `accessPolicy` here is a `ToggleableAccessPolicy`, deliberately independent of
    // `agentSettingsStore`, precisely so this combination is reachable in a test even though real
    // production wiring (`AgentSettingsAccessPolicy` reading the same `agentSettingsStore`
    // `AgentServer` does) couldn't actually produce it — the precedence still has to hold regardless
    // of what the store answers.
    let policy = ToggleableAccessPolicy(enabled: false)
    let settingsStore = writeAccessSettingsStore(writeAccessEnabled: true)
    let (server, _) = try await makeServer(
      accessPolicy: policy,
      items: [makeItem()],
      agentSettingsStore: settingsStore
    )
    _ = await send(.unlock, to: server)

    guard
      case .failure(.agentAccessDisabled) =
        await send(.createItem(makeItem(title: "Mail")), to: server, caller: cliCaller)
    else {
      Issue.record("expected .failure(.agentAccessDisabled)")
      return
    }
  }

  /// Regression test for the exact attack this ticket's toggle used to be vulnerable to (and, in an
  /// earlier draft of this branch, actually was): `agentWriteAccessEnabled` living on `AppSettings`,
  /// backed by the shared `com.851labs.lilpasswords.shared` `UserDefaults` suite that every local
  /// process — including a misbehaving agent — can freely rewrite with `defaults write
  /// com.851labs.lilpasswords.shared AppSettings.agentWriteAccessEnabled -bool true`, silently
  /// re-enabling its own write access. That property has never existed on `AppSettings` in this
  /// branch's final, rebased-onto-851-2428 shape (see that type's source) — `agentWriteAccessEnabled`
  /// is a field of ``AgentSettings``, persisted only through the helper-owned, ACL'd
  /// `AgentSettingsStoring`/`KeychainAgentSettingsStore` (see that protocol's documentation) — so
  /// there's nothing left for such a command to even name today. This test proves the actual runtime
  /// behavior rather than relying on "the property is gone" as the only evidence: it pokes the
  /// legacy suite/key pair directly, bypassing `AppSettings`'s Swift API entirely (exactly like the
  /// shell command above would), and confirms `AgentServer` — which reads write access exclusively
  /// from its injected `agentSettingsStore`, never from `UserDefaults` — is completely unaffected.
  @Test func tamperingWithTheSharedUserDefaultsSuiteHasNoEffectOnWriteAccess() async throws {
    let sharedDefaults = UserDefaults(suiteName: AppSettings.suiteName)!
    let legacyKey = "AppSettings.agentWriteAccessEnabled"
    let previousValue = sharedDefaults.object(forKey: legacyKey)
    defer {
      if let previousValue {
        sharedDefaults.set(previousValue, forKey: legacyKey)
      } else {
        sharedDefaults.removeObject(forKey: legacyKey)
      }
    }
    sharedDefaults.set(true, forKey: legacyKey)

    // The default `agentSettingsStore` (an empty `InMemoryAgentSettingsStore`) fails closed to
    // `.disabled` — matching a freshly launched helper that's never had the real, Keychain-backed
    // settings written at all — so if tampering with `UserDefaults` had any effect, this would flip
    // to `.success` instead.
    let (server, _) = try await makeServer()
    _ = await send(.unlock, to: server)

    guard
      case .failure(.agentWriteAccessDisabled) =
        await send(.createItem(makeItem(title: "Mail")), to: server, caller: cliCaller)
    else {
      Issue.record("expected .failure(.agentWriteAccessDisabled) even with the legacy UserDefaults key set to true")
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

  @Test func rotateRecoveryKeyIsRestrictedToTheAppEvenForARecognizedCliCaller() async throws {
    let (server, _) = try await makeServer()
    _ = await send(.unlock, to: server)

    guard case .failure(.callerNotAuthorized) = await send(.rotateRecoveryKey, to: server, caller: cliCaller) else {
      Issue.record("expected .failure(.callerNotAuthorized)")
      return
    }
  }

  @Test func rotateRecoveryKeyFailsWithLockedWhenTheVaultIsLocked() async throws {
    let (server, _) = try await makeServer()

    guard case .failure(.locked) = await send(.rotateRecoveryKey, to: server, caller: appCaller) else {
      Issue.record("expected .failure(.locked)")
      return
    }
  }

  /// The headline requirement: a successful `.rotateRecoveryKey` hands back a recovery key that
  /// actually works, and the moment it does, the *previous* recovery key stops working — there's
  /// no way left to unwrap the vault key with it.
  @Test func rotateRecoveryKeySucceedsForTheAppCallerAndTheOldRecoveryKeyStopsWorking() async throws {
    let store = InMemoryVaultStore()
    let server = AgentServer(vaultStore: store)

    guard
      case .success(.vaultCreated(let originalRecoveryKeyDisplayString)) =
        await send(.createVault, to: server, caller: appCaller)
    else {
      Issue.record("expected .vaultCreated")
      return
    }

    guard
      case .success(.recoveryKeyRotated(let newRecoveryKeyDisplayString)) =
        await send(.rotateRecoveryKey, to: server, caller: appCaller)
    else {
      Issue.record("expected .recoveryKeyRotated")
      return
    }
    #expect(newRecoveryKeyDisplayString != originalRecoveryKeyDisplayString)

    let originalRecoveryKey = try #require(VaultCrypto.RecoveryKey(displayString: originalRecoveryKeyDisplayString))
    await #expect(throws: VaultStoreError.incorrectKey) {
      _ = try await store.restoreKey(recoveryKey: originalRecoveryKey)
    }

    let newRecoveryKey = try #require(VaultCrypto.RecoveryKey(displayString: newRecoveryKeyDisplayString))
    let restoredKey = try await store.restoreKey(recoveryKey: newRecoveryKey)
    try await store.open(with: restoredKey)
    #expect(await store.isUnlocked)
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

  // MARK: - Agent settings (851-2428 security review)

  @Test func getAgentSettingsIsRestrictedToTheAppEvenForARecognizedCliCaller() async throws {
    let store = InMemoryVaultStore()
    let server = AgentServer(vaultStore: store)

    guard case .failure(.callerNotAuthorized) = await send(.getAgentSettings, to: server, caller: cliCaller) else {
      Issue.record("expected .failure(.callerNotAuthorized)")
      return
    }
  }

  @Test func setAgentSettingsIsRestrictedToTheAppEvenForARecognizedCliCaller() async throws {
    let store = InMemoryVaultStore()
    let server = AgentServer(vaultStore: store)
    let settings = AgentSettings(agentAccessEnabled: true, keepAgentAccessAvailableWhileMacUnlocked: true)

    guard
      case .failure(.callerNotAuthorized) = await send(.setAgentSettings(settings), to: server, caller: cliCaller)
    else {
      Issue.record("expected .failure(.callerNotAuthorized)")
      return
    }
  }

  @Test func getAgentSettingsFailsClosedWhenNothingHasEverBeenStored() async throws {
    let store = InMemoryVaultStore()
    let server = AgentServer(vaultStore: store, agentSettingsStore: InMemoryAgentSettingsStore())

    guard case .success(.agentSettings(let settings)) = await send(.getAgentSettings, to: server, caller: appCaller)
    else {
      Issue.record("expected .agentSettings")
      return
    }
    #expect(settings == .disabled)
  }

  @Test func getAgentSettingsFailsClosedWhenTheStoreIsUnreadable() async throws {
    struct BoomError: Error {}
    let store = InMemoryVaultStore()
    let settingsStore = InMemoryAgentSettingsStore(loadError: BoomError())
    let server = AgentServer(vaultStore: store, agentSettingsStore: settingsStore)

    guard case .success(.agentSettings(let settings)) = await send(.getAgentSettings, to: server, caller: appCaller)
    else {
      Issue.record("expected .agentSettings")
      return
    }
    #expect(settings == .disabled)
  }

  @Test func setAgentSettingsFromTheAppPersistsAndIsReflectedByAFollowingGet() async throws {
    let store = InMemoryVaultStore()
    let settingsStore = InMemoryAgentSettingsStore()
    let server = AgentServer(vaultStore: store, agentSettingsStore: settingsStore)
    let updated = AgentSettings(agentAccessEnabled: true, keepAgentAccessAvailableWhileMacUnlocked: true)

    guard
      case .success(.agentSettings(let echoed)) = await send(.setAgentSettings(updated), to: server, caller: appCaller)
    else {
      Issue.record("expected .agentSettings")
      return
    }
    #expect(echoed == updated)

    guard case .success(.agentSettings(let reread)) = await send(.getAgentSettings, to: server, caller: appCaller)
    else {
      Issue.record("expected .agentSettings")
      return
    }
    #expect(reread == updated)
  }

  @Test func agentSettingsRequestsAreNeverWrittenToTheAccessLog() async throws {
    let log = RecordingAccessLog()
    let store = InMemoryVaultStore()
    let server = AgentServer(vaultStore: store, accessLog: log)

    _ = await send(.getAgentSettings, to: server, caller: appCaller)
    _ = await send(.setAgentSettings(.disabled), to: server, caller: appCaller)

    let events = await log.events
    #expect(events.isEmpty)
  }

  // MARK: - 851-2441: AutoFill credential provider extension

  private func makeCredentialItem(
    title: String = "Netflix",
    username: String = "octocat",
    password: String = "hunter2",
    website: String? = "https://netflix.com"
  ) -> PasswordItem {
    PasswordItem(
      title: title,
      usernames: username.isEmpty ? [] : [username],
      password: password,
      websites: website.map { [URL(string: $0)!] } ?? [],
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  /// The structural half of "only return the credential for the chosen identity, not general
  /// list/search access": every request AutoFill *can't* reach should fail with
  /// `.callerNotAuthorized`, regardless of what `AccessPolicyProviding`/write-access/lock state
  /// would otherwise say — `isRequestPermitted(_:for:)` runs before any of that.
  @Test func autoFillCallerIsRejectedForEveryRequestExceptItsFive() async throws {
    let item = makeCredentialItem()
    let (server, _) = try await makeServer(items: [item])
    _ = await send(.unlock, to: server, caller: autoFillCaller)

    let disallowed: [AgentRequest] = [
      .createVault,
      .rotateRecoveryKey,
      .getAgentSettings,
      .setAgentSettings(.disabled),
      .list,
      .search(query: "netflix"),
      .getItem(.id(item.id)),
      .createItem(makeCredentialItem(title: "New")),
      .updateItem(item),
      .deleteItem(.id(item.id)),
      .generatePassword(.appleStrong),
      .totpCode(.id(item.id)),
    ]
    for request in disallowed {
      guard case .failure(.callerNotAuthorized) = await send(request, to: server, caller: autoFillCaller) else {
        Issue.record("expected .callerNotAuthorized for \(request)")
        continue
      }
    }
  }

  @Test func autoFillCallerCanUnlockLockAndCheckStatus() async throws {
    let (server, _) = try await makeServer()

    guard case .success(.unlocked) = await send(.unlock, to: server, caller: autoFillCaller) else {
      Issue.record("expected .unlocked")
      return
    }
    guard case .success(.status(let status)) = await send(.status, to: server, caller: autoFillCaller) else {
      Issue.record("expected .status")
      return
    }
    #expect(status.locked == false)
    guard case .success(.locked) = await send(.lock, to: server, caller: autoFillCaller) else {
      Issue.record("expected .locked")
      return
    }
  }

  @Test func autoFillIdentitiesMatchesByHostIgnoringSchemeAndWWW() async throws {
    let netflix = makeCredentialItem(title: "Netflix", website: "https://www.netflix.com/login")
    let github = makeCredentialItem(title: "GitHub", username: "octocat", website: "https://github.com")
    let noWebsite = makeCredentialItem(title: "No website", website: nil)
    let noUsername = makeCredentialItem(title: "No username", username: "", website: "https://noun.example")
    let (server, _) = try await makeServer(items: [netflix, github, noWebsite, noUsername])
    _ = await send(.unlock, to: server, caller: autoFillCaller)

    guard
      case .success(.autoFillIdentities(let identities)) = await send(
        .autoFillIdentities(serviceIdentifiers: ["netflix.com"]),
        to: server,
        caller: autoFillCaller
      )
    else {
      Issue.record("expected .autoFillIdentities")
      return
    }
    #expect(identities.map(\.title) == ["Netflix"])
    #expect(identities.first?.username == "octocat")

    guard
      case .success(.autoFillIdentities(let noMatches)) = await send(
        .autoFillIdentities(serviceIdentifiers: ["example.org"]),
        to: server,
        caller: autoFillCaller
      )
    else {
      Issue.record("expected .autoFillIdentities")
      return
    }
    #expect(noMatches.isEmpty)
  }

  @Test func autoFillCredentialReturnsOnlyUsernameAndPassword() async throws {
    let item = makeCredentialItem(username: "octocat", password: "hunter2")
    let (server, _) = try await makeServer(items: [item])
    _ = await send(.unlock, to: server, caller: autoFillCaller)

    guard
      case .success(.autoFillCredential(let username, let password)) = await send(
        .autoFillCredential(id: item.id),
        to: server,
        caller: autoFillCaller
      )
    else {
      Issue.record("expected .autoFillCredential")
      return
    }
    #expect(username == "octocat")
    #expect(password == "hunter2")
  }

  @Test func autoFillCredentialFailsWithNotFoundForAnUnknownOrDeletedId() async throws {
    let (server, _) = try await makeServer()
    _ = await send(.unlock, to: server, caller: autoFillCaller)

    guard
      case .failure(.notFound) = await send(.autoFillCredential(id: UUID()), to: server, caller: autoFillCaller)
    else {
      Issue.record("expected .notFound")
      return
    }
  }

  @Test func autoFillCredentialFailsWithLockedBeforeUnlock() async throws {
    let item = makeCredentialItem()
    let (server, _) = try await makeServer(items: [item])

    guard
      case .failure(.locked) = await send(.autoFillCredential(id: item.id), to: server, caller: autoFillCaller)
    else {
      Issue.record("expected .locked")
      return
    }
  }

  @Test func autoFillCallerIsExemptFromTheAgentAccessToggleLikeTheApp() async throws {
    let item = makeCredentialItem()
    let policy = AgentSettingsAccessPolicy(store: InMemoryAgentSettingsStore(initial: .disabled))
    let (server, _) = try await makeServer(accessPolicy: policy, items: [item])
    _ = await send(.unlock, to: server, caller: autoFillCaller)

    let outcome = await send(.autoFillCredential(id: item.id), to: server, caller: autoFillCaller)
    guard case .success(.autoFillCredential) = outcome else {
      Issue.record("expected .autoFillCredential even with agent access disabled")
      return
    }
  }

  // MARK: - Scoped agent access (851-2445)

  /// The headline policy matrix: for each of the three `AgentAccessScope` values, a non-app caller
  /// sees exactly the items the mode entitles it to — `.allPasswords` sees everything, `.selected`
  /// sees only the allowlisted item — while the app caller (`isAppCaller`) always sees everything,
  /// regardless of scope, exactly as it's exempt from every other agent-access toggle. `.askEveryTime`
  /// is covered separately below (it also depends on the approval outcome, not just the scope).
  @Test func accessScopeAllPasswordsExposesEveryItemToBothCallerKinds() async throws {
    let allowed = makeItem(title: "GitHub")
    let notAllowed = makeItem(title: "Mail")
    let settingsStore = scopedSettingsStore(accessScope: .allPasswords, allowedItemIDs: [allowed.id])
    let (server, _) = try await makeServer(items: [allowed, notAllowed], agentSettingsStore: settingsStore)
    _ = await send(.unlock, to: server)

    guard case .success(.items(let nonAppItems)) = await send(.list, to: server, caller: cliCaller) else {
      Issue.record("expected .items")
      return
    }
    #expect(Set(nonAppItems.map(\.id)) == Set([allowed.id, notAllowed.id]))

    guard case .success(.items(let appItems)) = await send(.list, to: server, caller: appCaller) else {
      Issue.record("expected .items")
      return
    }
    #expect(Set(appItems.map(\.id)) == Set([allowed.id, notAllowed.id]))
  }

  @Test func accessScopeSelectedFiltersListAndSearchToTheAllowlistForNonAppCallersOnly() async throws {
    let allowed = makeItem(title: "GitHub")
    let notAllowed = makeItem(title: "Mail")
    let settingsStore = scopedSettingsStore(accessScope: .selected, allowedItemIDs: [allowed.id])
    let (server, _) = try await makeServer(items: [allowed, notAllowed], agentSettingsStore: settingsStore)
    _ = await send(.unlock, to: server)

    guard case .success(.items(let nonAppItems)) = await send(.list, to: server, caller: cliCaller) else {
      Issue.record("expected .items")
      return
    }
    #expect(nonAppItems.map(\.id) == [allowed.id])

    guard case .success(.items(let appItems)) = await send(.list, to: server, caller: appCaller) else {
      Issue.record("expected .items")
      return
    }
    #expect(Set(appItems.map(\.id)) == Set([allowed.id, notAllowed.id]))
  }

  @Test func accessScopeSelectedAllowsAnItemThroughAnAllowedGroupToo() async throws {
    var allowed = makeItem(title: "GitHub")
    allowed.group = "Work"
    let notAllowed = makeItem(title: "Mail")
    let settingsStore = scopedSettingsStore(accessScope: .selected, allowedGroups: ["Work"])
    let (server, _) = try await makeServer(items: [allowed, notAllowed], agentSettingsStore: settingsStore)
    _ = await send(.unlock, to: server)

    guard case .success(.items(let items)) = await send(.list, to: server, caller: cliCaller) else {
      Issue.record("expected .items")
      return
    }
    #expect(items.map(\.id) == [allowed.id])
  }

  // MARK: - No existence leak (851-2445)

  @Test func selectedScopeGetItemByIdReportsNotFoundRatherThanTheItemForADisallowedId() async throws {
    let notAllowed = makeItem(title: "Mail")
    let settingsStore = scopedSettingsStore(accessScope: .selected, allowedItemIDs: [])
    let (server, _) = try await makeServer(items: [notAllowed], agentSettingsStore: settingsStore)
    _ = await send(.unlock, to: server)

    guard case .failure(.notFound) = await send(.getItem(.id(notAllowed.id)), to: server, caller: cliCaller) else {
      Issue.record("expected .failure(.notFound) — a disallowed item's existence must not leak")
      return
    }
  }

  /// The exact no-leak scenario ADR 0005 calls out: a query matches two items, only one of which
  /// is allowed. Filtering to the allowlist *before* the ambiguity check must resolve this as a
  /// single unambiguous match — surfacing `.ambiguous` here would itself leak "there's a second,
  /// invisible match somewhere" to a caller that isn't supposed to know the disallowed item exists.
  @Test func selectedScopeQueryMatchingOneAllowedAndOneDisallowedItemResolvesUnambiguously() async throws {
    let allowed = makeItem(title: "GitHub Work")
    let notAllowed = makeItem(title: "GitHub Personal")
    let settingsStore = scopedSettingsStore(accessScope: .selected, allowedItemIDs: [allowed.id])
    let (server, _) = try await makeServer(items: [allowed, notAllowed], agentSettingsStore: settingsStore)
    _ = await send(.unlock, to: server)

    guard case .success(.item(let item)) = await send(.getItem(.query("github")), to: server, caller: cliCaller)
    else {
      Issue.record("expected .success(.item) — an allowed match among matches must not read as ambiguous")
      return
    }
    #expect(item.id == allowed.id)
  }

  /// The mirror image: a query matches only disallowed items. This must read exactly like "no
  /// match at all" (`.notFound`), not `.ambiguous`/anything that would hint a match exists.
  @Test func selectedScopeQueryMatchingOnlyDisallowedItemsReportsNotFound() async throws {
    let a = makeItem(title: "GitHub Work")
    let b = makeItem(title: "GitHub Personal")
    let settingsStore = scopedSettingsStore(accessScope: .selected, allowedItemIDs: [])
    let (server, _) = try await makeServer(items: [a, b], agentSettingsStore: settingsStore)
    _ = await send(.unlock, to: server)

    guard case .failure(.notFound) = await send(.getItem(.query("github")), to: server, caller: cliCaller) else {
      Issue.record("expected .failure(.notFound)")
      return
    }
  }

  @Test func selectedScopeDeleteAndTotpCodeAlsoReportNotFoundForADisallowedItem() async throws {
    let notAllowed = PasswordItem(
      title: "Mail",
      totpURI: "otpauth://totp/Mail:octocat?secret=JBSWY3DPEHPK3PXP&issuer=Mail"
    )
    let settingsStore = scopedSettingsStore(accessScope: .selected, allowedItemIDs: [])
    let (server, _) = try await makeServer(items: [notAllowed], agentSettingsStore: settingsStore)
    _ = await send(.unlock, to: server)

    guard case .failure(.notFound) = await send(.totpCode(.id(notAllowed.id)), to: server, caller: cliCaller) else {
      Issue.record("expected .failure(.notFound) for totpCode")
      return
    }
    guard case .failure(.notFound) = await send(.deleteItem(.id(notAllowed.id)), to: server, caller: cliCaller)
    else {
      Issue.record("expected .failure(.notFound) for deleteItem")
      return
    }
  }

  @Test func selectedScopeUpdateItemFailsWithNotFoundForADisallowedItemEvenWithWriteAccessOn() async throws {
    let notAllowed = makeItem(title: "Mail")
    let settingsStore = scopedSettingsStore(accessScope: .selected, allowedItemIDs: [])
    let (server, _) = try await makeServer(items: [notAllowed], agentSettingsStore: settingsStore)
    _ = await send(.unlock, to: server)

    var updated = notAllowed
    updated.title = "Changed"
    guard case .failure(.notFound) = await send(.updateItem(updated), to: server, caller: cliCaller) else {
      Issue.record("expected .failure(.notFound)")
      return
    }
  }

  /// `.createItem` is never auto-added to the allowlist — a write-capable, `.selected`-scoped agent
  /// must not be able to silently expand its own read scope by creating a new item and expecting to
  /// see it again later. See docs/adr/0007-scoped-agent-access.md.
  @Test func selectedScopeCreatedItemIsNotAutomaticallyReadableByTheCreatingAgent() async throws {
    let settingsStore = scopedSettingsStore(accessScope: .selected, allowedItemIDs: [])
    let (server, _) = try await makeServer(agentSettingsStore: settingsStore)
    _ = await send(.unlock, to: server)

    let newItem = makeItem(title: "Mail")
    guard case .success(.created) = await send(.createItem(newItem), to: server, caller: cliCaller) else {
      Issue.record("expected .created")
      return
    }
    guard case .failure(.notFound) = await send(.getItem(.id(newItem.id)), to: server, caller: cliCaller) else {
      Issue.record("expected the newly created item to stay invisible to a .selected-scoped agent")
      return
    }
  }

  // MARK: - "Ask every time" approval (851-2445)

  @Test func askEveryTimeDeniesTheRequestAndSurfacesApprovalDeniedOrTimedOutOnATimeout() async throws {
    let item = makeItem()
    // A test-scale timeout: nothing ever calls `resolve(id:decision:)`, so this always times out.
    let approvalCenter = ApprovalCenter()
    let settingsStore = scopedSettingsStore(accessScope: .askEveryTime)
    let (server, _) = try await makeServer(
      items: [item],
      agentSettingsStore: settingsStore,
      approvalCenter: approvalCenter,
      approvalTimeout: .milliseconds(20)
    )
    _ = await send(.unlock, to: server)

    guard
      case .failure(.approvalDeniedOrTimedOut) = await send(.getItem(.id(item.id)), to: server, caller: cliCaller)
    else {
      Issue.record("expected .failure(.approvalDeniedOrTimedOut)")
      return
    }
  }

  @Test func askEveryTimeSucceedsOnceTheAppResolvesTheApprovalWithAllowOnce() async throws {
    let item = makeItem()
    let approvalCenter = ApprovalCenter()
    let settingsStore = scopedSettingsStore(accessScope: .askEveryTime)
    let (server, _) = try await makeServer(
      items: [item],
      agentSettingsStore: settingsStore,
      approvalCenter: approvalCenter,
      approvalTimeout: .seconds(10)
    )
    _ = await send(.unlock, to: server)

    async let outcome = send(.getItem(.id(item.id)), to: server, caller: cliCaller)

    // Give `requestApproval` a moment to actually park before resolving it — otherwise `resolve`
    // could race ahead of `pending[id]` being populated.
    var resolved = false
    for _ in 0..<200 {
      let summaries = await approvalCenter.pendingApprovals()
      if let pending = summaries.first {
        resolved = await approvalCenter.resolve(id: pending.id, decision: .allowOnce)
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(resolved)

    guard case .success(.item(let resolvedItem)) = await outcome else {
      Issue.record("expected .success(.item) once approved")
      return
    }
    #expect(resolvedItem.id == item.id)
  }

  /// `.askEveryTime` never gates the app's own connection — the same exemption every other
  /// agent-access toggle grants it.
  @Test func askEveryTimeNeverGatesTheAppCaller() async throws {
    let item = makeItem()
    let settingsStore = scopedSettingsStore(accessScope: .askEveryTime)
    let (server, _) = try await makeServer(
      items: [item],
      agentSettingsStore: settingsStore,
      approvalCenter: ApprovalCenter(),
      approvalTimeout: .milliseconds(20)
    )
    _ = await send(.unlock, to: server)

    guard case .success(.item(let fetched)) = await send(.getItem(.id(item.id)), to: server, caller: appCaller)
    else {
      Issue.record("expected .success(.item) — the app caller must never be gated by approval")
      return
    }
    #expect(fetched.id == item.id)
  }

  @Test func askEveryTimeDoesNotGateGeneratePassword() async throws {
    let settingsStore = scopedSettingsStore(accessScope: .askEveryTime)
    let (server, _) = try await makeServer(
      agentSettingsStore: settingsStore,
      approvalCenter: ApprovalCenter(),
      approvalTimeout: .milliseconds(20)
    )
    _ = await send(.unlock, to: server)

    guard
      case .success(.generatedPassword(let password)) =
        await send(.generatePassword(.appleStrong), to: server, caller: cliCaller)
    else {
      Issue.record("expected .success(.generatedPassword) — generating a password shouldn't need approval")
      return
    }
    #expect(!password.isEmpty)
  }

  @Test func accessLogRecordsTheAccessModeAndApprovalOutcome() async throws {
    let log = RecordingAccessLog()
    let item = makeItem()
    let approvalCenter = ApprovalCenter()
    let settingsStore = scopedSettingsStore(accessScope: .askEveryTime)
    let (server, _) = try await makeServer(
      accessLog: log,
      items: [item],
      agentSettingsStore: settingsStore,
      approvalCenter: approvalCenter,
      approvalTimeout: .milliseconds(20)
    )
    _ = await send(.unlock, to: server)

    _ = await send(.getItem(.id(item.id)), to: server, caller: cliCaller)

    let events = await log.events
    #expect(events.count == 1)
    #expect(events[0].accessMode == .askEveryTime)
    #expect(events[0].approvalOutcome == .deniedOrTimedOut)
  }
}
