import Foundation

/// A single vault operation reaching `AgentServer`, for the access log (851-2429) to persist.
///
/// **Never carries a secret value.** This is a structural guarantee, not a convention:
/// `AgentServer` only ever constructs an `AccessEvent` from the vault-operation branch of request
/// handling (`list`/`search`/`getItem`/`createItem`/`updateItem`/`deleteItem`/`generatePassword`
/// /`totpCode`) — `status`, `unlock`, and `lock` never reach ``AccessLogging/record(_:)`` at all,
/// specifically because `unlock`'s `UnlockPayload.sessionKey` is the raw vault key and must never
/// be handed to logging code, not even code that's currently a no-op. `request`'s other cases can
/// carry a full `PasswordItem` (`createItem`/`updateItem`), which does include `password` — the
/// real 851-2429 conformer is expected to log a summary (operation name, item id/title, which
/// fields were touched) rather than `request` verbatim; see that ticket's description for the
/// exact shape wanted in the Settings → Agents UI.
public struct AccessEvent: Sendable {
  public var date: Date
  public var caller: CallerIdentity
  public var request: AgentRequest
  public var succeeded: Bool

  public init(date: Date = Date(), caller: CallerIdentity, request: AgentRequest, succeeded: Bool) {
    self.date = date
    self.caller = caller
    self.request = request
    self.succeeded = succeeded
  }
}

/// **Seam**: 851-2429 supplies the real conformer — the on-disk, 30-day, filterable access log
/// described in that ticket. `AgentServer` calls ``record(_:)`` after every vault operation,
/// successful or not (a denied attempt, e.g. while locked or agent access disabled, is still
/// worth a log entry).
public protocol AccessLogging: Sendable {
  func record(_ event: AccessEvent) async
}

/// Does nothing. Used by `LilPasswordsAgent` until 851-2429 lands, and by tests that don't care
/// about logging.
public struct NoOpAccessLog: AccessLogging {
  public init() {}
  public func record(_ event: AccessEvent) async {}
}
