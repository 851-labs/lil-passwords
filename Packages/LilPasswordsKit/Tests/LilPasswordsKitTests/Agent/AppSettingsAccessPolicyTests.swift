import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct AppSettingsAccessPolicyTests {
  /// Each test gets its own throwaway `UserDefaults` suite, matching `AppSettingsTests`, so tests
  /// can't see each other's (or the real app's) preferences.
  private func makeSettings() -> AppSettings {
    let suiteName = "com.851labs.lilpasswords.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return AppSettings(defaults: defaults)
  }

  private let appCaller = CallerIdentity(
    pid: 1,
    processPath: "/Applications/Lil Passwords.app/Contents/MacOS/Lil Passwords",
    parentProcessName: "launchd"
  )
  private let cliCaller = CallerIdentity(pid: 2, processPath: "/usr/local/bin/lilpw", parentProcessName: "zsh")

  @Test func isAgentAccessEnabledReflectsTheSettingLive() async {
    let settings = makeSettings()
    let policy = AppSettingsAccessPolicy(settings: settings)

    #expect(await policy.isAgentAccessEnabled() == false)
    settings.agentAccessEnabled = true
    #expect(await policy.isAgentAccessEnabled() == true)
    settings.agentAccessEnabled = false
    #expect(await policy.isAgentAccessEnabled() == false)
  }

  @Test func nonAppCallerIsAllowedOnlyWhenTheToggleIsOn() async {
    let settings = makeSettings()
    let policy = AppSettingsAccessPolicy(settings: settings, isAppCaller: { _ in false })

    #expect(await policy.isAccessAllowed(for: cliCaller) == false)
    settings.agentAccessEnabled = true
    #expect(await policy.isAccessAllowed(for: cliCaller) == true)
    settings.agentAccessEnabled = false
    #expect(await policy.isAccessAllowed(for: cliCaller) == false)
  }

  @Test func appCallerIsAlwaysExemptFromTheToggle() async {
    let settings = makeSettings()
    let policy = AppSettingsAccessPolicy(settings: settings, isAppCaller: { _ in true })

    #expect(settings.agentAccessEnabled == false)
    #expect(await policy.isAccessAllowed(for: appCaller) == true)

    settings.agentAccessEnabled = true
    #expect(await policy.isAccessAllowed(for: appCaller) == true)
  }

  @Test func defaultIsAppCallerMatchesOnlyTheAppsOwnExecutableName() {
    #expect(AppSettingsAccessPolicy.defaultIsAppCaller(appCaller) == true)
    #expect(AppSettingsAccessPolicy.defaultIsAppCaller(cliCaller) == false)

    let unresolved = CallerIdentity(pid: 3, processPath: nil, parentProcessName: nil)
    #expect(AppSettingsAccessPolicy.defaultIsAppCaller(unresolved) == false)
  }

  @Test func keepAgentAccessAvailableWhileMacUnlockedReflectsTheSettingLive() {
    let settings = makeSettings()
    let policy = AppSettingsAccessPolicy(settings: settings)

    #expect(policy.keepAgentAccessAvailableWhileMacUnlocked == false)
    settings.keepAgentAccessAvailableWhileMacUnlocked = true
    #expect(policy.keepAgentAccessAvailableWhileMacUnlocked == true)
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
      // A non-app caller (`lilpw`/an agent) needs both the toggle on *and* the vault unlocked;
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
      let settings = makeSettings()
      settings.agentAccessEnabled = testCase.agentAccessEnabled

      let store = InMemoryVaultStore()
      try await store.createVault()
      let key = try await store.currentKey()
      await store.lock()

      let policy = AppSettingsAccessPolicy(settings: settings, isAppCaller: { _ in testCase.callerIsApp })
      let server = AgentServer(vaultStore: store, accessPolicy: policy)

      if testCase.isUnlocked {
        let unlockOutcome = await server.handle(
          AgentRequestEnvelope(request: .unlock(UnlockPayload(sessionKey: key.rawData, keyId: key.id))),
          caller: appCaller
        ).outcome
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
