import Testing

@testable import LilPasswordsKit

@Suite struct AgentConnectionSecurityTests {
  @Test func nilTeamIdentifierFallsBackToDevelopmentModeInsteadOfEnforcing() {
    let requirement = AgentConnectionSecurity.requirement(acceptingPeers: [.app, .cli], teamIdentifier: nil)

    guard case .developmentFallback(let reason) = requirement else {
      Issue.record("expected .developmentFallback, got \(requirement)")
      return
    }
    #expect(!reason.isEmpty)
  }

  @Test func aRealTeamIdentifierProducesASyntacticallyValidEnforcedRequirement() {
    let requirement = AgentConnectionSecurity.requirement(acceptingPeers: [.app, .cli], teamIdentifier: "WH4QW9ND3J")

    guard case .enforce(let text) = requirement else {
      Issue.record("expected .enforce, got \(requirement)")
      return
    }
    #expect(text.contains("WH4QW9ND3J"))
    #expect(text.contains("com.851labs.lilpasswords\""))
    #expect(text.contains("com.851labs.lilpasswords.cli"))
    #expect(!text.contains("com.851labs.lilpasswords.agent\""))
  }

  @Test func acceptingASinglePeerOnlyMentionsThatIdentifier() {
    let requirement = AgentConnectionSecurity.requirement(acceptingPeers: [.agent], teamIdentifier: "WH4QW9ND3J")

    guard case .enforce(let text) = requirement else {
      Issue.record("expected .enforce, got \(requirement)")
      return
    }
    #expect(text.contains("com.851labs.lilpasswords.agent\""))
    #expect(!text.contains("com.851labs.lilpasswords.cli"))
  }

  @Test func currentProcessTeamIdentifierDoesNotCrashForTheTestBinary() {
    // The test binary is normally unsigned or ad-hoc signed, so this is typically `nil` — but the
    // point of this test is just that calling it is safe (it shouldn't throw or crash) regardless
    // of how the binary running the test suite happens to be signed.
    _ = AgentConnectionSecurity.currentProcessTeamIdentifier()
  }
}
