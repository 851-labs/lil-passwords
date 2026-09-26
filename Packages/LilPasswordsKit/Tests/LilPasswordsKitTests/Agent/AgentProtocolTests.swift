import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct AgentProtocolTests {
  private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try AgentWireCoding.encoder.encode(value)
    return try AgentWireCoding.decoder.decode(T.self, from: data)
  }

  private func makeItem() -> PasswordItem {
    // `AgentWireCoding` encodes dates as ISO 8601 without fractional seconds, so a `PasswordItem`
    // built with the default `Date()` timestamps (which do have sub-second precision) wouldn't
    // round-trip back to an `==` value — pin `createdAt`/`modifiedAt` to whole seconds instead.
    let wholeSecond = Date(timeIntervalSince1970: 1_700_000_000)
    return PasswordItem(
      title: "GitHub",
      usernames: ["octocat"],
      password: "correct-horse-battery-staple",
      websites: [URL(string: "https://github.com")!],
      notes: "",
      totpURI: nil,
      group: nil,
      createdAt: wholeSecond,
      modifiedAt: wholeSecond
    )
  }

  @Test func itemReferenceRoundTripsByIdAndByQuery() throws {
    let id = UUID()
    #expect(try roundTrip(ItemReference.id(id)) == .id(id))
    #expect(try roundTrip(ItemReference.query("github")) == .query("github"))
  }

  @Test func everyRequestCaseRoundTrips() throws {
    let item = makeItem()
    let requests: [AgentRequest] = [
      .status,
      .createVault,
      .unlock,
      .lock,
      .list,
      .search(query: "github"),
      .getItem(.id(item.id)),
      .createItem(item),
      .updateItem(item),
      .deleteItem(.query("github")),
      .generatePassword(.appleStrong),
      .generatePassword(.custom(length: 20, characterCategories: .all)),
      .totpCode(.id(item.id)),
    ]

    for request in requests {
      #expect(try roundTrip(request) == request)
    }
  }

  @Test func everyResponseCaseRoundTrips() throws {
    let item = makeItem()
    let responses: [AgentResponse] = [
      .status(AgentStatus(locked: true, agentAccessEnabled: false, vaultExists: true)),
      .vaultCreated(recoveryKeyDisplayString: "4S9K-D2XQ-7RTN-8YCB-J3WM"),
      .unlocked,
      .locked,
      .items([item]),
      .item(item),
      .created(item),
      .updated(item),
      .deleted,
      .generatedPassword("abcdef-ghijk2-lmNopq"),
      .totpCode(TOTPCodeResult(code: "123456", expiresAt: Date(timeIntervalSince1970: 30))),
    ]

    for response in responses {
      #expect(try roundTrip(response) == response)
    }
  }

  @Test func everyErrorCaseRoundTripsAndDescribesItself() throws {
    let errors: [AgentError] = [
      .locked,
      .agentAccessDisabled,
      .notFound,
      .ambiguous,
      .unsupportedProtocolVersion(requested: 99, supported: AgentProtocolVersion.current),
      .callerNotAuthorized,
      .internal(message: "something went wrong"),
    ]

    for error in errors {
      #expect(try roundTrip(error) == error)
      #expect(!error.description.isEmpty)
    }

    #expect(AgentError.locked.description == "lil passwords is locked — unlock the app")
  }

  @Test func outcomeRoundTripsBothSuccessAndFailure() throws {
    #expect(try roundTrip(AgentOutcome.success(.locked)) == .success(.locked))
    #expect(try roundTrip(AgentOutcome.failure(.locked)) == .failure(.locked))
  }

  @Test func requestEnvelopeDefaultsToCurrentProtocolVersion() {
    let envelope = AgentRequestEnvelope(request: .status)
    #expect(envelope.version == AgentProtocolVersion.current)
  }

  @Test func replyEnvelopeDefaultsToCurrentProtocolVersion() {
    let envelope = AgentReplyEnvelope(outcome: .success(.locked))
    #expect(envelope.version == AgentProtocolVersion.current)
  }

  @Test func requestEnvelopeRoundTripsThroughData() throws {
    let envelope = AgentRequestEnvelope(request: .search(query: "github"))
    let data = try AgentWireCoding.encoder.encode(envelope)
    let decoded = try AgentWireCoding.decoder.decode(AgentRequestEnvelope.self, from: data)
    #expect(decoded == envelope)
  }
}
