import Foundation

@testable import LilPasswordsKit

/// The same in-process `AgentServer` + `InMemoryVaultStore` + anonymous `NSXPCListener` harness
/// `LilpwCoreTests` uses (see `Tests/LilpwCoreTests/Support/Harness.swift`), duplicated here rather
/// than shared: SwiftPM doesn't allow a single file to belong to two test targets, and there's no
/// non-test target this could move into without losing `@testable import`'s access to
/// `AgentClient`'s test-only `AgentClient(endpoint:connectionSecurity:)` initializer. Keep the two
/// copies in sync if either changes.
///
/// `LilpwMCPTests` uses this to drive `LilpwMCP.makeServer(client:)` against a real, launchd-free
/// XPC round trip instead of a hand-rolled fake `AgentClient`, the same way `LilpwCoreTests` tests
/// `LilpwCore`'s command logic.
final class Harness {
  let server: AgentServer
  let listener: NSXPCListener
  let delegate: AgentXPCListenerDelegate
  let client: AgentClient
  let key: VaultCrypto.Key

  /// Mirrors `AgentXPCEndToEndTests.Harness` (851-2411): `.unlock` is a payload-less intent, so the
  /// vault key has to be reachable some other way for the in-process helper to read back — an
  /// `InMemoryVaultKeyStore` seeded with the same key `store.createVault()` generated, exactly as
  /// a real `KeychainVaultKeyStore` would already have it by the time a real app sends `.unlock`.
  /// Likewise, this in-process XPC connection's peer resolves to the *test binary's* own real
  /// code-signing identity (not `nil`), so `appCallerBundleIdentifier` is told to trust that
  /// identity as "the app" the same way that harness does. Keep this in sync with
  /// `LilpwCoreTests/Support/Harness.swift` if either changes.
  init(
    items: [PasswordItem] = [],
    accessPolicy: any AccessPolicyProviding = AlwaysAllowAccessPolicy(),
    unlocked: Bool = true
  ) async throws {
    let store = InMemoryVaultStore()
    let keyStore = InMemoryVaultKeyStore()
    try await store.createVault()
    key = try await store.currentKey()
    try keyStore.store(key)
    for item in items {
      try await store.create(item)
    }
    if !unlocked {
      await store.lock()
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
    delegate = AgentXPCListenerDelegate(server: server, connectionSecurity: .developmentFallback(reason: "test"))
    listener.delegate = delegate
    listener.resume()
    client = AgentClient(endpoint: listener.endpoint, connectionSecurity: .developmentFallback(reason: "test"))
  }

  deinit {
    listener.invalidate()
  }

  func unlock() async throws {
    try await client.unlock()
  }
}

/// A `PasswordItem` pinned to whole-second timestamps, matching `AgentServerTests`/
/// `AgentXPCEndToEndTests`'s own helper: `AgentWireCoding`'s `.iso8601` date strategy drops
/// sub-second precision, so a default `Date()` timestamp wouldn't round-trip to an `==` value once
/// it crosses the wire.
func makeTestItem(
  title: String = "GitHub",
  usernames: [String] = ["octocat"],
  password: String = "hunter2",
  websites: [URL] = [],
  notes: String = "",
  totpURI: String? = nil,
  group: String? = nil
) -> PasswordItem {
  PasswordItem(
    title: title,
    usernames: usernames,
    password: password,
    websites: websites,
    notes: notes,
    totpURI: totpURI,
    group: group,
    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
    modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
  )
}
