import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct AccessLogEntryTests {
  private var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  /// `AccessLogEntry.init(from:)` must keep decoding an on-disk JSONL row written before 851-2445
  /// added `accessMode`/`approvalOutcome` — no such keys at all in the persisted JSON — falling back
  /// to `.allPasswords`/`nil`, the same defaults `init(...)` uses. The exact backward-compatibility
  /// pattern `AgentSettings.init(from:)` already established for 851-2433's `agentWriteAccessEnabled`.
  @Test func decodesPre851_2445JSONLMissingAccessModeAndApprovalOutcomeWithFailClosedDefaults() throws {
    let legacyJSON = """
      {
        "id": "\(UUID().uuidString)",
        "date": "2024-01-01T00:00:00Z",
        "operation": "getItem",
        "callerChain": ["lilpass", "claude"],
        "succeeded": true,
        "itemId": "\(UUID().uuidString)",
        "itemTitle": "GitHub",
        "fields": ["title", "password"]
      }
      """
    let entry = try decoder.decode(AccessLogEntry.self, from: Data(legacyJSON.utf8))
    #expect(entry.accessMode == .allPasswords)
    #expect(entry.approvalOutcome == nil)
    #expect(entry.operation == "getItem")
    #expect(entry.itemTitle == "GitHub")
  }

  @Test func roundTripsWithAccessModeAndApprovalOutcomePresent() throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let entry = AccessLogEntry(
      date: Date(timeIntervalSince1970: 1_700_000_000),
      operation: "getItem",
      callerChain: ["lilpass", "claude"],
      succeeded: true,
      itemId: UUID(),
      itemTitle: "GitHub",
      fields: ["title", "password"],
      accessMode: .askEveryTime,
      approvalOutcome: .grantedOnce
    )
    let data = try encoder.encode(entry)
    let decoded = try decoder.decode(AccessLogEntry.self, from: data)
    #expect(decoded == entry)
  }

  @Test func callerDescriptionRendersOutermostCallerFirst() {
    let entry = AccessLogEntry(
      date: Date(),
      operation: "list",
      callerChain: ["lilpass", "node", "claude"],
      succeeded: true
    )
    #expect(entry.callerDescription == "claude → node → lilpass")
  }

  @Test func callerDescriptionFallsBackToUnknownWhenTheChainIsEmpty() {
    let entry = AccessLogEntry(date: Date(), operation: "list", callerChain: [], succeeded: true)
    #expect(entry.callerDescription == "unknown")
  }
}
