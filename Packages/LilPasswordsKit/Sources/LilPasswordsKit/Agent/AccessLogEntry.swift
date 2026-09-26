import Foundation

/// One row of the access log (851-2429): a redacted, display-ready summary of a single
/// `AccessEvent` `AgentServer` already finished handling.
///
/// Deliberately **not** `AccessEvent` itself, and deliberately without an `AgentRequest`/
/// `AgentResponse` payload of any kind — both wire types can carry a secret value
/// (`AgentRequest.createItem`/`.updateItem` embed a full `PasswordItem`, including `password`;
/// `AgentResponse.generatedPassword`/`.item`/`.totpCode` do too). Keeping those types out of this
/// struct's `Codable` surface entirely — rather than, say, `Codable` conformance that happens to
/// skip a `password` key today — means this struct's on-disk JSONL shape can never start leaking a
/// secret just because `AgentRequest`/`AgentResponse` gained a field later. See
/// `AccessEventSummary.entry(for:)` for the one place that does read `AccessEvent`'s wire-level
/// request/response to build one of these.
public struct AccessLogEntry: Sendable, Codable, Equatable, Identifiable {
  public var id: UUID
  public var date: Date

  /// The operation name, e.g. `"list"`, `"getItem"`, `"createItem"` — always one of
  /// `AccessEventSummary`'s fixed set, never a raw `AgentRequest` case name via reflection, so this
  /// stays stable even if `AgentRequest`'s Swift case names ever change.
  public var operation: String

  /// The calling process chain, immediate caller first — e.g. `["lilpass", "node", "claude"]` — for
  /// ``callerDescription`` to render as `"claude → node → lilpass"`. May be a single element, or
  /// empty if nothing could be resolved at all.
  public var callerChain: [String]

  public var succeeded: Bool

  /// The item this operation touched, if any and if it could be determined — `nil` for
  /// `list`/`search` (many items, not one) and for a query-based `deleteItem` (see
  /// `AccessEventSummary`'s documentation on why that specific case can't recover an id).
  public var itemId: UUID?
  public var itemTitle: String?

  /// Non-secret field *names* this operation touched — e.g. `["title", "username", "password"]`.
  /// Naming that the `"password"` field was touched is the entire point of an audit log; this
  /// array never contains a field's actual *value*, only that a field by that name was read or
  /// written. See ``AccessEventSummary`` for exactly how this is derived per operation.
  public var fields: [String]

  /// The Settings → Agents access mode (851-2445) in effect for this event — see
  /// `AccessEvent.accessMode`.
  public var accessMode: AgentAccessScope

  /// How a live `.askEveryTime` approval (if one ran) was resolved — see
  /// `AccessEvent.approvalOutcome`.
  public var approvalOutcome: ApprovalOutcome?

  public init(
    id: UUID = UUID(),
    date: Date,
    operation: String,
    callerChain: [String],
    succeeded: Bool,
    itemId: UUID? = nil,
    itemTitle: String? = nil,
    fields: [String] = [],
    accessMode: AgentAccessScope = .allPasswords,
    approvalOutcome: ApprovalOutcome? = nil
  ) {
    self.id = id
    self.date = date
    self.operation = operation
    self.callerChain = callerChain
    self.succeeded = succeeded
    self.itemId = itemId
    self.itemTitle = itemTitle
    self.fields = fields
    self.accessMode = accessMode
    self.approvalOutcome = approvalOutcome
  }

  private enum CodingKeys: String, CodingKey {
    case id, date, operation, callerChain, succeeded, itemId, itemTitle, fields, accessMode, approvalOutcome
  }

  /// A custom, rather than synthesized, `Decodable` conformance so an on-disk JSONL entry written
  /// before 851-2445 added ``accessMode``/``approvalOutcome`` (no such keys in its stored JSON at
  /// all) still decodes instead of throwing — falling back to ``AgentAccessScope/allPasswords``/
  /// `nil`, the same defaults `init(...)` above uses, the same backward-compatibility pattern
  /// `AgentSettings.init(from:)` established for 851-2433.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    date = try container.decode(Date.self, forKey: .date)
    operation = try container.decode(String.self, forKey: .operation)
    callerChain = try container.decode([String].self, forKey: .callerChain)
    succeeded = try container.decode(Bool.self, forKey: .succeeded)
    itemId = try container.decodeIfPresent(UUID.self, forKey: .itemId)
    itemTitle = try container.decodeIfPresent(String.self, forKey: .itemTitle)
    fields = try container.decodeIfPresent([String].self, forKey: .fields) ?? []
    accessMode = try container.decodeIfPresent(AgentAccessScope.self, forKey: .accessMode) ?? .allPasswords
    approvalOutcome = try container.decodeIfPresent(ApprovalOutcome.self, forKey: .approvalOutcome)
  }

  /// Display string for the Settings → Agents table's "Agent" column, e.g. `"claude → node → lilpass"`
  /// (outermost caller first, `lilpass`/the resolved executable last), or `"unknown"` if
  /// ``callerChain`` couldn't be resolved at all.
  public var callerDescription: String {
    callerChain.isEmpty ? "unknown" : callerChain.reversed().joined(separator: " → ")
  }

  /// Display string for the "Item" column — the title if known, an id if only that's known (the
  /// query-based `deleteItem` gap noted on ``itemId``), or an em dash for an operation with no
  /// single item at all (`list`/`search`/`generatePassword`).
  public var itemDescription: String {
    if let itemTitle { return itemTitle }
    if let itemId { return itemId.uuidString }
    return "—"
  }
}

/// Turns one `AccessEvent` — the wire-level request/response `AgentServer` just finished handling —
/// into the redacted ``AccessLogEntry`` the access log actually stores. The only place in 851-2429
/// that reads `AgentRequest`/`AgentResponse` at all, so every other access-log type
/// (``AccessLogEntry``, ``AccessLogStore``) can stay ignorant of the wire protocol's shape, and by
/// extension of what it can carry.
enum AccessEventSummary {
  static func entry(for event: AccessEvent) -> AccessLogEntry {
    let summary = summarize(event)
    let resolvedChain = CallerIdentityResolver.resolveProcessChain(pid: event.caller.pid)
    return AccessLogEntry(
      date: event.date,
      operation: summary.operation,
      callerChain: resolvedChain.isEmpty ? fallbackChain(for: event.caller) : resolvedChain,
      succeeded: event.succeeded,
      itemId: summary.itemId,
      itemTitle: summary.itemTitle,
      fields: summary.fields,
      accessMode: event.accessMode,
      approvalOutcome: event.approvalOutcome
    )
  }

  /// Falls back to whatever `CallerIdentity` itself resolved at connection-accept time, for the
  /// (expected to be rare, but real) case where ``CallerIdentityResolver/resolveProcessChain(pid:maxDepth:)``
  /// comes back empty — most likely a short-lived CLI invocation whose pid has already been
  /// recycled by the time this runs.
  private static func fallbackChain(for caller: CallerIdentity) -> [String] {
    var chain: [String] = []
    if let processPath = caller.processPath { chain.append((processPath as NSString).lastPathComponent) }
    if let parentProcessName = caller.parentProcessName { chain.append(parentProcessName) }
    return chain
  }

  private struct Summary {
    var operation: String
    var itemId: UUID?
    var itemTitle: String?
    var fields: [String]
  }

  /// Every non-secret field name reported for a bulk `list`/`search` response: both return whole
  /// items, and what the caller actually does with each field afterward isn't visible here, so
  /// this reports every field an item *could* expose rather than understating access.
  private static let allNonSecretFieldNames = ["title", "username", "password", "website", "notes", "totp"]

  private static func summarize(_ event: AccessEvent) -> Summary {
    switch event.request {
    case .list:
      return Summary(operation: "list", itemId: nil, itemTitle: nil, fields: allNonSecretFieldNames)

    case .search:
      return Summary(operation: "search", itemId: nil, itemTitle: nil, fields: allNonSecretFieldNames)

    case .getItem(let reference):
      if case .item(let item) = event.response {
        return Summary(
          operation: "getItem",
          itemId: item.id,
          itemTitle: item.title,
          fields: nonSecretFieldNames(of: item)
        )
      }
      return Summary(operation: "getItem", itemId: reference.directId, itemTitle: nil, fields: [])

    case .createItem(let item):
      return Summary(
        operation: "createItem",
        itemId: item.id,
        itemTitle: item.title,
        fields: nonSecretFieldNames(of: item)
      )

    case .updateItem(let item):
      return Summary(
        operation: "updateItem",
        itemId: item.id,
        itemTitle: item.title,
        fields: nonSecretFieldNames(of: item)
      )

    case .deleteItem(let reference):
      // `AgentResponse.deleted` carries no payload, so a query-based delete can only be logged
      // with the operation name and (if it was an id-based reference to begin with) the id — see
      // `AccessEvent.response`'s documentation for why this is a deliberate, accepted gap rather
      // than a reason to add a payload to `.deleted`.
      return Summary(operation: "deleteItem", itemId: reference.directId, itemTitle: nil, fields: [])

    case .generatePassword:
      return Summary(operation: "generatePassword", itemId: nil, itemTitle: nil, fields: ["password"])

    case .totpCode(let reference):
      return Summary(operation: "totpCode", itemId: reference.directId, itemTitle: nil, fields: ["totp"])

    case .autoFillIdentities:
      // 851-2441: no single item (a list, like `.list`/`.search`), and never a password — the
      // response type itself (`[CredentialIdentity]`) structurally cannot carry one.
      return Summary(operation: "autoFillIdentities", itemId: nil, itemTitle: nil, fields: ["username", "website"])

    case .autoFillCredential(let id):
      // Unlike `.getItem`, this can only ever have touched "username" and "password" — the
      // response type (`AgentResponse.autoFillCredential(username:password:)`) has no other fields
      // to report, by construction.
      return Summary(operation: "autoFillCredential", itemId: id, itemTitle: nil, fields: ["username", "password"])

    case .passkeys:
      // 851-2442: a list, like `.list`/`.search` — no single item, and the response
      // (`[PasskeyMetadata]`) structurally cannot carry a private key.
      return Summary(
        operation: "passkeys", itemId: nil, itemTitle: nil, fields: ["relyingPartyIdentifier", "userName"])

    case .passkeyIdentities:
      // 851-2442: app-only, powers `CredentialIdentityStoreSyncCoordinator` — a list, like
      // `.passkeys`, but also reports that `credentialId` (never a private key) was read, since
      // this is the one op where that's true.
      return Summary(
        operation: "passkeyIdentities", itemId: nil, itemTitle: nil,
        fields: ["relyingPartyIdentifier", "userName", "credentialId"]
      )

    case .deletePasskey(let id):
      return Summary(operation: "deletePasskey", itemId: id, itemTitle: nil, fields: [])

    case .passkeyRegister(let request):
      // Never logs `privateKeyPKCS8`/`credentialId` — neither is even present on
      // `PasskeyRegistrationRequest`/`PasskeyRegistrationResult`; see AgentProtocol.swift.
      return Summary(
        operation: "passkeyRegister",
        itemId: nil,
        itemTitle: request.relyingPartyIdentifier,
        fields: ["relyingPartyIdentifier", "userName"]
      )

    case .passkeyAssert:
      // Never logs the signature or the key that produced it — only that an assertion happened.
      return Summary(operation: "passkeyAssert", itemId: nil, itemTitle: nil, fields: ["relyingPartyIdentifier"])

    case .status, .createVault, .unlock, .lock, .getAgentSettings, .setAgentSettings, .rotateRecoveryKey,
      .pendingApprovals, .resolveApproval:
      preconditionFailure(
        "AgentServer never sends lock-lifecycle/helper-configuration requests to the access log"
      )
    }
  }

  /// Non-secret field *names* present on `item` — never the field's *value*. Reporting that the
  /// `"password"` field was accessed is the entire point of an audit log (an agent read a
  /// password); reporting the password's actual characters would defeat it. Fields the item
  /// doesn't actually have (e.g. no notes, no TOTP) are omitted so the log doesn't claim more
  /// access happened than did.
  private static func nonSecretFieldNames(of item: PasswordItem) -> [String] {
    var fields = ["title"]
    if !item.usernames.isEmpty { fields.append("username") }
    if !item.password.isEmpty { fields.append("password") }
    if !item.websites.isEmpty { fields.append("website") }
    if !item.notes.isEmpty { fields.append("notes") }
    if let totpURI = item.totpURI, !totpURI.isEmpty { fields.append("totp") }
    return fields
  }
}

extension ItemReference {
  fileprivate var directId: UUID? {
    if case .id(let id) = self { return id }
    return nil
  }
}
