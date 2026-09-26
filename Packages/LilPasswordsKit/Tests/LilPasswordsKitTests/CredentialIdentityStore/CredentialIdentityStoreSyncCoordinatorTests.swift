import Foundation
import Testing

@testable import LilPasswordsKit

/// 851-2441: exercises ``CredentialIdentityStoreSyncCoordinator/refresh()`` — the coordinator's one
/// testable entry point (see its own documentation for why ``CredentialIdentityStoreSyncCoordinator
/// /start()`` itself, a thin `CFNotificationCenter` wrapper, is deliberately left untested, matching
/// this package's existing treatment of `LockStateObserver`/`DarwinNotificationObserver`) — against
/// a real `AgentClient` bound to an in-process, anonymous-listener `AgentServer`, with a fake
/// ``CredentialIdentityStoreSyncing`` spy standing in for the real system call.
@Suite struct CredentialIdentityStoreSyncCoordinatorTests {
  /// Records every `sync(items:)` call it receives, in order, so tests can assert both *whether*
  /// a sync happened and *which* items it was handed.
  private final actor SpySyncer: CredentialIdentityStoreSyncing {
    private(set) var calls: [[PasswordItem]] = []

    func sync(items: [PasswordItem]) async {
      calls.append(items)
    }
  }

  /// A minimal replica of `AgentXPCEndToEndTests.Harness` (that type is `private` to its own
  /// file): a real `NSXPCListener.anonymous()`/`AgentServer` pair, seeded with `items` and left
  /// locked, with this test process itself trusted as the app caller — matching what
  /// `AgentClient` needs to make a real `.list()` XPC call succeed once unlocked.
  private final class Harness {
    let client: AgentClient
    private let listener: NSXPCListener
    private let delegate: AgentXPCListenerDelegate

    init(items: [PasswordItem]) async throws {
      let store = InMemoryVaultStore()
      let keyStore = InMemoryVaultKeyStore()
      try await store.createVault()
      let vaultKey = try await store.currentKey()
      try keyStore.store(vaultKey)
      for item in items {
        try await store.create(item)
      }
      await store.lock()

      let selfIdentity = CallerIdentityResolver.resolve(pid: ProcessInfo.processInfo.processIdentifier)
      let resolvedSelfIdentifier = selfIdentity.bundleIdentifier ?? AgentConnectionSecurity.PeerIdentifier.app.rawValue
      let server = AgentServer(
        vaultStore: store,
        vaultKeyStore: keyStore,
        accessPolicy: AlwaysAllowAccessPolicy(),
        appCallerBundleIdentifier: resolvedSelfIdentifier
      )
      let connectionSecurity = AgentConnectionSecurity.Requirement.developmentFallback(reason: "test")
      listener = NSXPCListener.anonymous()
      delegate = AgentXPCListenerDelegate(server: server, connectionSecurity: connectionSecurity)
      listener.delegate = delegate
      listener.resume()
      client = AgentClient(endpoint: listener.endpoint, connectionSecurity: connectionSecurity)
    }

    deinit {
      listener.invalidate()
    }
  }

  @Test func refreshSyncsTheCurrentItemsWhenUnlocked() async throws {
    let item = PasswordItem(
      title: "Netflix",
      usernames: ["octocat"],
      password: "hunter2",
      websites: [URL(string: "https://www.netflix.com")!]
    )
    let harness = try await Harness(items: [item])
    try await harness.client.unlock()
    let syncer = SpySyncer()
    let coordinator = await CredentialIdentityStoreSyncCoordinator(agentClient: harness.client, syncer: syncer)

    await coordinator.refresh()

    let calls = await syncer.calls
    #expect(calls.count == 1)
    #expect(calls[0].map(\.id) == [item.id])
  }

  @Test func refreshDoesNothingWhenLocked() async throws {
    let harness = try await Harness(items: [])
    // Deliberately never unlocked — `AgentClient.list()` should throw `.locked`, and the
    // coordinator should swallow that rather than calling the syncer at all.
    let syncer = SpySyncer()
    let coordinator = await CredentialIdentityStoreSyncCoordinator(agentClient: harness.client, syncer: syncer)

    await coordinator.refresh()

    let calls = await syncer.calls
    #expect(calls.isEmpty)
  }

  @Test func refreshReflectsAnEmptyVaultAfterUnlock() async throws {
    let harness = try await Harness(items: [])
    try await harness.client.unlock()
    let syncer = SpySyncer()
    let coordinator = await CredentialIdentityStoreSyncCoordinator(agentClient: harness.client, syncer: syncer)

    await coordinator.refresh()

    let calls = await syncer.calls
    #expect(calls == [[]])
  }
}
