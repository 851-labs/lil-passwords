import LilPasswordsKit
import LilpwCore
import Testing

@Suite struct LilpwExitCodeTests {
  @Test func passesLilpwErrorThrough() {
    let original = LilpwError(exitCode: .usage, message: "bad --field value")
    #expect(LilpwError.from(original) == original)
  }

  @Test func mapsConnectionFailureToHelperUnreachable() {
    let error = AgentClient.RequestError.connection(.invalidated(reason: "test"))
    #expect(LilpwError.from(error).exitCode == .helperUnreachable)
  }

  @Test func mapsRemoteLockedToLocked() {
    let error = AgentClient.RequestError.remote(.locked)
    #expect(LilpwError.from(error).exitCode == .locked)
  }

  @Test func mapsRemoteAgentAccessDisabledToAgentAccessDisabled() {
    let error = AgentClient.RequestError.remote(.agentAccessDisabled)
    #expect(LilpwError.from(error).exitCode == .agentAccessDisabled)
  }

  @Test func mapsRemoteNotFoundToNotFound() {
    let error = AgentClient.RequestError.remote(.notFound)
    #expect(LilpwError.from(error).exitCode == .notFound)
  }

  @Test func mapsRemoteAmbiguousToAmbiguous() {
    let error = AgentClient.RequestError.remote(.ambiguous)
    #expect(LilpwError.from(error).exitCode == .ambiguous)
  }

  @Test func mapsRemoteInternalErrorToGeneric() {
    let error = AgentClient.RequestError.remote(.internal(message: "boom"))
    #expect(LilpwError.from(error).exitCode == .generic)
  }

  @Test func mapsUnsupportedProtocolVersionToGeneric() {
    let error = AgentClient.RequestError.remote(.unsupportedProtocolVersion(requested: 2, supported: 1))
    #expect(LilpwError.from(error).exitCode == .generic)
  }

  @Test func mapsAnUnrecognizedErrorToGeneric() {
    struct SomeOtherError: Error {}
    #expect(LilpwError.from(SomeOtherError()).exitCode == .generic)
  }
}
