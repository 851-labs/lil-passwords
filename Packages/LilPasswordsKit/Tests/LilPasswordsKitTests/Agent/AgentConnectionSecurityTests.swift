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

  @Test func acceptingThreePeersMentionsAllThreeIdentifiers() {
    // 851-2441: `Agent/Sources/main.swift` accepts `[.app, .cli, .autoFill]` in production — the
    // requirement string must actually list all three, or the AutoFill extension's connection
    // would be silently refused at the code-signing layer before ever reaching `AgentServer`.
    let requirement = AgentConnectionSecurity.requirement(
      acceptingPeers: [.app, .cli, .autoFill],
      teamIdentifier: "WH4QW9ND3J"
    )

    guard case .enforce(let text) = requirement else {
      Issue.record("expected .enforce, got \(requirement)")
      return
    }
    #expect(text.contains("com.851labs.lilpasswords\""))
    #expect(text.contains("com.851labs.lilpasswords.cli"))
    #expect(text.contains("com.851labs.lilpasswords.autofill"))
  }

  @Test func nilTeamIdentifierInADebugBuildFallsBackToDevelopmentModeInsteadOfRejecting() {
    let requirement = AgentConnectionSecurity.requirement(
      acceptingPeers: [.app, .cli],
      teamIdentifier: nil,
      isDebugBuild: true
    )

    guard case .developmentFallback(let reason) = requirement else {
      Issue.record("expected .developmentFallback, got \(requirement)")
      return
    }
    #expect(!reason.isEmpty)
  }

  @Test func nilTeamIdentifierInAReleaseBuildRejectsEveryConnectionInsteadOfFallingBack() {
    // The security-critical case this policy exists for: a Release build with no team identifier
    // has no safe way to validate a peer, so it must fail closed rather than reuse DEBUG's
    // accept-anything fallback — see `AgentConnectionSecurity.Requirement.rejectAll`'s docs.
    let requirement = AgentConnectionSecurity.requirement(
      acceptingPeers: [.app, .cli],
      teamIdentifier: nil,
      isDebugBuild: false
    )

    guard case .rejectAll(let reason) = requirement else {
      Issue.record("expected .rejectAll, got \(requirement)")
      return
    }
    #expect(!reason.isEmpty)
  }

  @Test func aRealTeamIdentifierEnforcesRegardlessOfDebugVsRelease() {
    // The DEBUG/Release policy only changes what happens when there's *no* team identifier to
    // build a real requirement from — a real team identifier always produces `.enforce`, since
    // there's no reason to ever prefer the unauthenticated fallback when real validation is
    // possible.
    for isDebugBuild in [true, false] {
      let requirement = AgentConnectionSecurity.requirement(
        acceptingPeers: [.app, .cli],
        teamIdentifier: "WH4QW9ND3J",
        isDebugBuild: isDebugBuild
      )
      guard case .enforce = requirement else {
        Issue.record("expected .enforce for isDebugBuild=\(isDebugBuild), got \(requirement)")
        return
      }
    }
  }

  @Test func currentProcessTeamIdentifierDoesNotCrashForTheTestBinary() {
    // The test binary is normally unsigned or ad-hoc signed, so this is typically `nil` — but the
    // point of this test is just that calling it is safe (it shouldn't throw or crash) regardless
    // of how the binary running the test suite happens to be signed.
    _ = AgentConnectionSecurity.currentProcessTeamIdentifier()
  }
}
