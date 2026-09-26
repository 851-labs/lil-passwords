import Foundation
import Testing

@testable import LilPasswordsKit

/// 851-2465: `UnlockFailure.describing(_:)` is what stands between a raw `AgentClient.RequestError`
/// (or any other thrown `Error`) and the lock screen — these tests pin down its two load-bearing
/// promises: every `.connection` case collapses to the exact friendly sentence the ticket calls
/// for (never the underlying reason string), and `isHelperUnreachable` is set precisely when a
/// "Try Again"/Login Items affordance would actually help.
@Suite struct UnlockFailureTests {
  @Test func aConnectionInvalidatedErrorBecomesTheFriendlyHelperUnreachableMessage() {
    let error = AgentClient.RequestError.connection(
      .invalidated(reason: "Couldn't communicate with a helper application.")
    )

    let failure = UnlockFailure.describing(error)

    #expect(failure.message == "Couldn't reach \(LilPasswordsKit.productName)' background helper.")
    #expect(failure.isHelperUnreachable)
    // The raw reason must never leak into the displayed message.
    #expect(!failure.message.contains("Couldn't communicate with a helper application."))
  }

  @Test func anInvalidReplyConnectionErrorAlsoBecomesTheFriendlyHelperUnreachableMessage() {
    let error = AgentClient.RequestError.connection(.invalidReply)

    let failure = UnlockFailure.describing(error)

    #expect(failure.message == "Couldn't reach \(LilPasswordsKit.productName)' background helper.")
    #expect(failure.isHelperUnreachable)
  }

  @Test func aRemoteAgentErrorPassesThroughItsOwnFriendlyDescriptionAndIsNotHelperUnreachable() {
    let error = AgentClient.RequestError.remote(.agentAccessDisabled)

    let failure = UnlockFailure.describing(error)

    #expect(failure.message == AgentError.agentAccessDisabled.description)
    #expect(!failure.isHelperUnreachable)
  }

  @Test func aRemoteLockedErrorPassesThroughItsOwnFriendlyDescription() {
    let error = AgentClient.RequestError.remote(.locked)

    let failure = UnlockFailure.describing(error)

    #expect(failure.message == AgentError.locked.description)
    #expect(!failure.isHelperUnreachable)
  }

  @Test func anUnrelatedErrorFallsBackToItsOwnDescriptionAndIsNotHelperUnreachable() {
    struct SomeOtherError: Error, CustomStringConvertible {
      var description: String { "authentication was cancelled" }
    }

    let failure = UnlockFailure.describing(SomeOtherError())

    #expect(failure.message == "authentication was cancelled")
    #expect(!failure.isHelperUnreachable)
  }
}
