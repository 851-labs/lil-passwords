import LilPasswordsKit
import LilpassCore
import Testing

@Suite struct LilpassExitCodeTests {
  @Test func passesLilpassErrorThrough() {
    let original = LilpassError(exitCode: .usage, message: "bad --field value")
    #expect(LilpassError.from(original) == original)
  }

  @Test func mapsConnectionFailureToHelperUnreachable() {
    let error = AgentClient.RequestError.connection(.invalidated(reason: "test"))
    #expect(LilpassError.from(error).exitCode == .helperUnreachable)
  }

  @Test func mapsRemoteLockedToLocked() {
    let error = AgentClient.RequestError.remote(.locked)
    #expect(LilpassError.from(error).exitCode == .locked)
  }

  @Test func mapsRemoteAgentAccessDisabledToAgentAccessDisabled() {
    let error = AgentClient.RequestError.remote(.agentAccessDisabled)
    #expect(LilpassError.from(error).exitCode == .agentAccessDisabled)
  }

  @Test func mapsRemoteAgentWriteAccessDisabledToItsOwnExitCode() {
    let error = AgentClient.RequestError.remote(.agentWriteAccessDisabled)
    #expect(LilpassError.from(error).exitCode == .agentWriteAccessDisabled)
    // 851-2430 already claimed exit codes 0-7; 851-2433's new case must not collide with any of
    // them or with any future ticket picking the "next" code without checking here first.
    #expect(LilpassExitCode.agentWriteAccessDisabled.rawValue == 8)
  }

  @Test func mapsRemoteNotFoundToNotFound() {
    let error = AgentClient.RequestError.remote(.notFound)
    #expect(LilpassError.from(error).exitCode == .notFound)
  }

  @Test func mapsRemoteAmbiguousToAmbiguous() {
    let error = AgentClient.RequestError.remote(.ambiguous)
    #expect(LilpassError.from(error).exitCode == .ambiguous)
  }

  @Test func mapsRemoteApprovalDeniedOrTimedOutToItsOwnExitCode() {
    let error = AgentClient.RequestError.remote(.approvalDeniedOrTimedOut)
    #expect(LilpassError.from(error).exitCode == .approvalDeniedOrTimedOut)
    // 851-2430/851-2433 already claimed exit codes 0-8; 851-2445's new case must not collide with
    // any of them or with any future ticket picking the "next" code without checking here first.
    #expect(LilpassExitCode.approvalDeniedOrTimedOut.rawValue == 9)
  }

  @Test func mapsRemoteInternalErrorToGeneric() {
    let error = AgentClient.RequestError.remote(.internal(message: "boom"))
    #expect(LilpassError.from(error).exitCode == .generic)
  }

  @Test func mapsUnsupportedProtocolVersionToGeneric() {
    let error = AgentClient.RequestError.remote(.unsupportedProtocolVersion(requested: 2, supported: 1))
    #expect(LilpassError.from(error).exitCode == .generic)
  }

  @Test func mapsAnUnrecognizedErrorToGeneric() {
    struct SomeOtherError: Error {}
    #expect(LilpassError.from(SomeOtherError()).exitCode == .generic)
  }
}
