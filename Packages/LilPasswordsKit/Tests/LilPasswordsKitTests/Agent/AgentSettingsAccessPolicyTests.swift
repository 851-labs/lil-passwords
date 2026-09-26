import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct AgentSettingsAccessPolicyTests {
  private let appCaller = CallerIdentity(
    pid: 1,
    processPath: "/Applications/lil passwords.app/Contents/MacOS/lil passwords",
    parentProcessName: "launchd",
    bundleIdentifier: AgentConnectionSecurity.PeerIdentifier.app.rawValue
  )
  private let cliCaller = CallerIdentity(
    pid: 2,
    processPath: "/usr/local/bin/lilpass",
    parentProcessName: "zsh",
    bundleIdentifier: AgentConnectionSecurity.PeerIdentifier.cli.rawValue
  )

  @Test func isAgentAccessEnabledReflectsTheSettingLive() async {
    let store = InMemoryAgentSettingsStore()
    let policy = AgentSettingsAccessPolicy(store: store)

    #expect(await policy.isAgentAccessEnabled() == false)
    try? store.store(AgentSettings(agentAccessEnabled: true, keepAgentAccessAvailableWhileMacUnlocked: false))
    #expect(await policy.isAgentAccessEnabled() == true)
    try? store.store(AgentSettings(agentAccessEnabled: false, keepAgentAccessAvailableWhileMacUnlocked: false))
    #expect(await policy.isAgentAccessEnabled() == false)
  }

  @Test func nonAppCallerIsAllowedOnlyWhenTheToggleIsOn() async {
    let store = InMemoryAgentSettingsStore()
    let policy = AgentSettingsAccessPolicy(store: store, isAppCaller: { _ in false })

    #expect(await policy.isAccessAllowed(for: cliCaller) == false)
    try? store.store(AgentSettings(agentAccessEnabled: true, keepAgentAccessAvailableWhileMacUnlocked: false))
    #expect(await policy.isAccessAllowed(for: cliCaller) == true)
    try? store.store(AgentSettings(agentAccessEnabled: false, keepAgentAccessAvailableWhileMacUnlocked: false))
    #expect(await policy.isAccessAllowed(for: cliCaller) == false)
  }

  @Test func appCallerIsAlwaysExemptFromTheToggle() async {
    let store = InMemoryAgentSettingsStore()
    let policy = AgentSettingsAccessPolicy(store: store, isAppCaller: { _ in true })

    #expect(await policy.isAgentAccessEnabled() == false)
    #expect(await policy.isAccessAllowed(for: appCaller) == true)

    try? store.store(AgentSettings(agentAccessEnabled: true, keepAgentAccessAvailableWhileMacUnlocked: false))
    #expect(await policy.isAccessAllowed(for: appCaller) == true)
  }

  @Test func keepAgentAccessAvailableWhileMacUnlockedReflectsTheSettingLive() {
    let store = InMemoryAgentSettingsStore()
    let policy = AgentSettingsAccessPolicy(store: store)

    #expect(policy.keepAgentAccessAvailableWhileMacUnlocked == false)
    try? store.store(AgentSettings(agentAccessEnabled: false, keepAgentAccessAvailableWhileMacUnlocked: true))
    #expect(policy.keepAgentAccessAvailableWhileMacUnlocked == true)
  }

  /// Both blockers from the 851-2428 security review are missing-settings/unreadable-store cases
  /// too — this just confirms the policy shares `AgentSettings.loaded(from:)` with `AgentServer`
  /// rather than independently re-deriving "treat as disabled".
  @Test func failsClosedWhenTheStoreHasNeverBeenWrittenTo() async {
    let policy = AgentSettingsAccessPolicy(store: InMemoryAgentSettingsStore())
    #expect(await policy.isAgentAccessEnabled() == false)
    #expect(policy.keepAgentAccessAvailableWhileMacUnlocked == false)
  }

  @Test func failsClosedWhenTheStoreIsUnreadable() async {
    struct BoomError: Error {}
    let policy = AgentSettingsAccessPolicy(store: InMemoryAgentSettingsStore(loadError: BoomError()))
    #expect(await policy.isAgentAccessEnabled() == false)
    #expect(policy.keepAgentAccessAvailableWhileMacUnlocked == false)
  }

  // MARK: - defaultIsAppCaller / isVerifiedApp (851-2428 security review — Blocker 1)
  //
  // Before the review, `defaultIsAppCaller` compared `caller.processPath`'s last path component
  // against the product name — a plain, spoofable string: `cp lilpass "/tmp/lil passwords"` inherits
  // `lilpass`'s own code signature but ends up at a path named "lil passwords", so that old
  // comparison would have misidentified it as the app. `defaultIsAppCaller` now delegates entirely
  // to `CallerIdentity.isVerifiedApp(appBundleIdentifier:)`, which reads only the verified,
  // code-signing-resolved `bundleIdentifier` — never `processPath` — so a caller's path is
  // irrelevant to the result.

  @Test func defaultIsAppCallerMatchesTheAppsVerifiedBundleIdentifier() {
    #expect(AgentSettingsAccessPolicy.defaultIsAppCaller(appCaller) == true)
    #expect(AgentSettingsAccessPolicy.defaultIsAppCaller(cliCaller) == false)
  }

  @Test func defaultIsAppCallerFallsBackToIsDebugBuildWhenNoBundleIdentifierIsResolved() {
    let unresolved = CallerIdentity(pid: 3, processPath: nil, parentProcessName: nil)
    #expect(AgentSettingsAccessPolicy.defaultIsAppCaller(unresolved) == AgentConnectionSecurity.isDebugBuild)
  }

  /// The exact regression the orchestrator's review asked for: a CLI-signed peer whose path has
  /// been renamed to look like the app is still *not* the app, because the check never reads the
  /// path.
  @Test func aCLISignedPeerAtAPathNamedLilPasswordsIsNotTheApp() {
    let spoofedPathCLICaller = CallerIdentity(
      pid: 4,
      processPath: "/tmp/lil passwords",
      parentProcessName: "zsh",
      bundleIdentifier: AgentConnectionSecurity.PeerIdentifier.cli.rawValue
    )
    #expect(AgentSettingsAccessPolicy.defaultIsAppCaller(spoofedPathCLICaller) == false)
    #expect(spoofedPathCLICaller.isVerifiedApp() == false)
  }

  // MARK: - Full matrix, end to end through AgentServer: enabled/disabled × locked/unlocked × app/CLI caller

  private struct MatrixCase: CustomStringConvertible {
    var agentAccessEnabled: Bool
    var isUnlocked: Bool
    var callerIsApp: Bool
    var expected: AgentOutcome

    var description: String {
      "agentAccessEnabled=\(agentAccessEnabled) isUnlocked=\(isUnlocked) callerIsApp=\(callerIsApp)"
    }
  }

  @Test func fullPolicyLockAndCallerMatrix() async throws {
    let cases: [MatrixCase] = [
      // A non-app caller (`lilpass`/an agent) needs both the toggle on *and* the vault unlocked;
      // the toggle is checked first, so a disabled toggle always reports `.agentAccessDisabled`
      // regardless of lock state — never `.locked` (matches
      // `AgentServerTests.agentAccessDisabledTakesPrecedenceOverAnUnlockedStore`).
      MatrixCase(
        agentAccessEnabled: false, isUnlocked: false, callerIsApp: false, expected: .failure(.agentAccessDisabled)),
      MatrixCase(
        agentAccessEnabled: false, isUnlocked: true, callerIsApp: false, expected: .failure(.agentAccessDisabled)),
      MatrixCase(agentAccessEnabled: true, isUnlocked: false, callerIsApp: false, expected: .failure(.locked)),
      MatrixCase(agentAccessEnabled: true, isUnlocked: true, callerIsApp: false, expected: .success(.items([]))),

      // The app's own connection is exempt from the toggle entirely — "it's the UI" — so its only
      // remaining gate is the vault's own lock state, same as if the toggle were always on.
      MatrixCase(agentAccessEnabled: false, isUnlocked: false, callerIsApp: true, expected: .failure(.locked)),
      MatrixCase(agentAccessEnabled: false, isUnlocked: true, callerIsApp: true, expected: .success(.items([]))),
      MatrixCase(agentAccessEnabled: true, isUnlocked: false, callerIsApp: true, expected: .failure(.locked)),
      MatrixCase(agentAccessEnabled: true, isUnlocked: true, callerIsApp: true, expected: .success(.items([]))),
    ]

    for testCase in cases {
      let settingsStore = InMemoryAgentSettingsStore()
      try settingsStore.store(
        AgentSettings(
          agentAccessEnabled: testCase.agentAccessEnabled,
          keepAgentAccessAvailableWhileMacUnlocked: false
        )
      )

      let store = InMemoryVaultStore()
      try await store.createVault()
      let key = try await store.currentKey()
      await store.lock()

      // `.unlock` is payload-less: the helper reads the vault key back from `vaultKeyStore`
      // itself (851-2411), so a test that wants a real `.unlock` to succeed has to seed the same
      // key there first — matching `AgentServerTests.makeServer`'s own setup.
      let keyStore = InMemoryVaultKeyStore()
      try keyStore.store(key)

      let policy = AgentSettingsAccessPolicy(store: settingsStore, isAppCaller: { _ in testCase.callerIsApp })
      let server = AgentServer(vaultStore: store, vaultKeyStore: keyStore, accessPolicy: policy)

      if testCase.isUnlocked {
        let unlockOutcome = await server.handle(AgentRequestEnvelope(request: .unlock), caller: appCaller).outcome
        guard case .success = unlockOutcome else {
          Issue.record("failed to unlock for \(testCase): \(unlockOutcome)")
          continue
        }
      }

      let caller = testCase.callerIsApp ? appCaller : cliCaller
      let outcome = await server.handle(AgentRequestEnvelope(request: .list), caller: caller).outcome
      #expect(outcome == testCase.expected, "\(testCase)")
    }
  }
}
