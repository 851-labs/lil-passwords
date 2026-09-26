import Foundation

/// A single vault operation reaching `AgentServer`, for the access log (851-2429) to persist.
///
/// **Never carries a secret value.** This is a structural guarantee, not a convention:
/// `AgentServer` only ever constructs an `AccessEvent` from the vault-operation branch of request
/// handling (`list`/`search`/`getItem`/`createItem`/`updateItem`/`deleteItem`/`generatePassword`
/// /`totpCode`) — `status`, `createVault`, `unlock`, and `lock` never reach
/// ``AccessLogging/record(_:)`` at all: `unlock` is payload-less (the helper reads the vault key
/// itself from the Keychain — see `VaultKeyStoring` — so there's never any key material in the
/// request to begin with), but these four are excluded uniformly as a matter of scope, not because
/// any one of them individually happens to carry a secret. `request`'s other cases can
/// carry a full `PasswordItem` (`createItem`/`updateItem`), which does include `password` — the
/// real 851-2429 conformer is expected to log a summary (operation name, item id/title, which
/// fields were touched) rather than `request` verbatim; see that ticket's description for the
/// exact shape wanted in the Settings → Agents UI.
public struct AccessEvent: Sendable {
  public var date: Date
  public var caller: CallerIdentity
  public var request: AgentRequest
  public var succeeded: Bool

  /// The response `AgentServer` produced for `request`, when `succeeded` — `nil` on failure (there
  /// is none) or if a caller building an `AccessEvent` by hand doesn't have one (e.g. existing
  /// tests written before this property existed; defaulted so they keep compiling unchanged).
  ///
  /// This exists so a real ``AccessLogging`` conformer can recover the item id/title a
  /// query-based `getItem(.query(...))` resolved to — `request` alone only has the raw query
  /// string, not which item it matched. `deleteItem` has no equivalent: its response
  /// (`AgentResponse.deleted`) carries no payload at all, so a query-based delete is logged with
  /// only the operation name and no item id/title — a deliberate, documented gap rather than a
  /// reason to add a payload to `.deleted` and risk a wire-protocol conflict with concurrent work
  /// on `AgentProtocol.swift`.
  public var response: AgentResponse?

  public init(
    date: Date = Date(),
    caller: CallerIdentity,
    request: AgentRequest,
    response: AgentResponse? = nil,
    succeeded: Bool
  ) {
    self.date = date
    self.caller = caller
    self.request = request
    self.response = response
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
