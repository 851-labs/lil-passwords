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
      .rotateRecoveryKey,
      .list,
      .search(query: "github"),
      .getItem(.id(item.id)),
      .createItem(item),
      .updateItem(item),
      .deleteItem(.query("github")),
      .generatePassword(.appleStrong),
      .generatePassword(.custom(length: 20, characterCategories: .all)),
      .totpCode(.id(item.id)),
      .autoFillIdentities(serviceIdentifiers: ["netflix.com", "github.com"]),
      .autoFillCredential(id: item.id),
      .pendingApprovals,
      .resolveApproval(id: UUID(), decision: .allowOnce),
      .resolveApproval(id: UUID(), decision: .allowFor15Minutes),
      .resolveApproval(id: UUID(), decision: .deny),
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
      .recoveryKeyRotated(recoveryKeyDisplayString: "7RTN-4S9K-J3WM-D2XQ-8YCB"),
      .items([item]),
      .item(item),
      .created(item),
      .updated(item),
      .deleted,
      .generatedPassword("abcdef-ghijk2-lmNopq"),
      .totpCode(TOTPCodeResult(code: "123456", expiresAt: Date(timeIntervalSince1970: 30))),
      .autoFillIdentities([
        CredentialIdentity(
          id: item.id,
          title: item.title,
          username: "octocat",
          website: URL(string: "https://netflix.com")
        ),
        CredentialIdentity(id: .v7(), title: "No website", username: "someone", website: nil),
      ]),
      .autoFillCredential(username: "octocat", password: "hunter2"),
      .pendingApprovals([
        PendingApprovalSummary(
          requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
          agentDescription: "claude",
          itemTitle: "GitHub",
          operationDescription: "wants to read the password for"
        )
      ]),
      .approvalResolved,
    ]

    for response in responses {
      #expect(try roundTrip(response) == response)
    }
  }

  @Test func everyErrorCaseRoundTripsAndDescribesItself() throws {
    let errors: [AgentError] = [
      .locked,
      .agentAccessDisabled,
      .agentWriteAccessDisabled,
      .notFound,
      .ambiguous,
      .unsupportedProtocolVersion(requested: 99, supported: AgentProtocolVersion.current),
      .callerNotAuthorized,
      .internal(message: "something went wrong"),
      .approvalDeniedOrTimedOut,
    ]

    for error in errors {
      #expect(try roundTrip(error) == error)
      #expect(!error.description.isEmpty)
    }

    #expect(AgentError.locked.description == "lil passwords is locked — unlock the app")
    #expect(AgentError.approvalDeniedOrTimedOut.description == "approval denied or timed out")
  }

  // MARK: - Scoped agent access (851-2445)

  @Test func agentAccessScopeRoundTrips() throws {
    for scope: AgentAccessScope in [.allPasswords, .selected, .askEveryTime] {
      #expect(try roundTrip(scope) == scope)
    }
  }

  @Test func approvalDecisionRoundTrips() throws {
    for decision: ApprovalDecision in [.allowOnce, .allowFor15Minutes, .deny] {
      #expect(try roundTrip(decision) == decision)
    }
  }

  @Test func pendingApprovalSummaryRoundTrips() throws {
    let summary = PendingApprovalSummary(
      requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
      agentDescription: "claude",
      itemTitle: "GitHub",
      operationDescription: "wants to read the password for"
    )
    #expect(try roundTrip(summary) == summary)
  }

  /// `AgentSettings.init(from:)` must keep decoding a Keychain item written before 851-2445 added
  /// `accessScope`/`allowedItemIDs`/`allowedGroups` — no such keys at all in the persisted JSON —
  /// falling back to `.allPasswords`/empty sets, the same fail-closed defaults `init(...)` uses.
  /// This is the exact backward-compatibility pattern 851-2433's `agentWriteAccessEnabled` already
  /// established for this type; see that field's `CodingKeys`/`init(from:)` for precedent.
  @Test func agentSettingsDecodesPre851_2445JSONMissingScopeFieldsWithFailClosedDefaults() throws {
    let legacyJSON = """
      {
        "agentAccessEnabled": true,
        "keepAgentAccessAvailableWhileMacUnlocked": true,
        "agentWriteAccessEnabled": true
      }
      """
    let decoded = try JSONDecoder().decode(AgentSettings.self, from: Data(legacyJSON.utf8))
    #expect(decoded.accessScope == .allPasswords)
    #expect(decoded.allowedItemIDs.isEmpty)
    #expect(decoded.allowedGroups.isEmpty)
    #expect(decoded.agentAccessEnabled == true)
    #expect(decoded.agentWriteAccessEnabled == true)
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
