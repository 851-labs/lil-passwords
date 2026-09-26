import Foundation

/// The versioned request/response protocol `LilPasswordsAgent` serves over its Mach service.
///
/// The wire shape is deliberately dumb: XPC only ever marshals `Data` (see `AgentXPCProtocol`),
/// and every real operation lives in these Swift `Codable` enums instead of in `@objc`-compatible
/// method signatures. That keeps the type system's full richness (associated values, nested
/// structs, `Result`-shaped error handling) instead of flattening everything into
/// `NSSecureCoding`-compatible primitives, and it means adding an operation never touches the
/// `@objc` surface at all.
public enum AgentProtocolVersion {
  /// The protocol version this build of `LilPasswordsKit` speaks. `AgentServer` rejects any
  /// `AgentRequestEnvelope` whose `version` doesn't match with
  /// ``AgentError/unsupportedProtocolVersion(requested:supported:)`` rather than guessing at
  /// compatibility — see that case's documentation for why there's no attempt at partial
  /// forward/backward compatibility yet.
  public static let current = 1
}

/// A reference to a single vault item, either by its stable id or by a free-text query matched
/// against the same fields as ``AgentRequest/search(query:)``.
///
/// Letting `getItem`/`deleteItem`/`totpCode` accept either shape is what makes
/// `AgentError.ambiguous` meaningful: `.query("github")` can match zero, one, or several items,
/// while `.id` either exists or doesn't (``AgentError/notFound``, never `.ambiguous`).
public enum ItemReference: Sendable, Codable, Equatable {
  case id(UUID)
  case query(String)
}

/// Every operation `LilPasswordsAgent` supports.
public enum AgentRequest: Sendable, Codable, Equatable {
  /// Whether the vault is locked/unlocked and whether agent access is currently enabled. Always
  /// answerable, regardless of lock state or the 851-2428 toggle.
  case status

  /// First run: asks the helper to generate a fresh vault key, create the vault, and persist the
  /// key to the local Keychain — see `VaultKeyStoring`. Restricted to the app itself (never
  /// `lilpass`); see `AgentError.callerNotAuthorized`.
  case createVault

  /// An unlock **intent**, carrying no key material at all: the caller performs `LAContext`
  /// authentication (Touch ID/Apple Watch/login password) first, then sends this so the helper
  /// reads the vault key itself from the local Keychain (`VaultKeyStoring`) and opens the store.
  /// The key never leaves the helper process — see docs/adr/0001-storage-and-process-model.md (b).
  /// Restricted to the app **and** the 851-2441 AutoFill credential provider extension — both
  /// perform their own `LAContext` authentication before sending this (the extension's "Unlock"
  /// button in `prepareInterfaceToProvideCredential`, the app's lock screen), so both get the same
  /// trust `AgentServer.isAppCaller(_:)`/`isAutoFillCaller(_:)` verify by code signature. Never
  /// `lilpass`. Authenticated by the connection's code-signing requirement rather than anything in
  /// this payload.
  case unlock

  /// Discards the in-memory vault key and any open store. Idempotent.
  case lock

  /// Regenerates the vault's recovery key: generates a new `VaultCrypto.RecoveryKey`, re-wraps
  /// the current vault key under it, and replaces the wrapped copy in `meta` — the previous
  /// recovery key stops working immediately. The vault must already be unlocked; the app is
  /// expected to perform `LAContext` authentication before sending this, the same as it does
  /// before `.unlock`. Restricted to the app itself, the same as `.createVault`/`.unlock`; see
  /// `AgentError.callerNotAuthorized`.
  case rotateRecoveryKey

  /// Every item in the vault.
  case list

  /// Items matching a free-text query.
  case search(query: String)

  /// A single item, by id or query. Fails with ``AgentError/ambiguous`` if a query matches more
  /// than one item, or ``AgentError/notFound`` if it matches none.
  case getItem(ItemReference)

  /// Adds a new item.
  case createItem(PasswordItem)

  /// Replaces an existing item (matched by `PasswordItem.id`).
  case updateItem(PasswordItem)

  /// Removes an item, by id or query (see ``getItem(_:)`` for the ambiguity rule).
  case deleteItem(ItemReference)

  /// Generates a password without touching the vault.
  case generatePassword(PasswordGenerator.Format)

  /// The current TOTP code for an item, by id or query (see ``getItem(_:)`` for the ambiguity
  /// rule). Fails with `AgentError.internal` if the item has no `totpURI`, or one that fails to
  /// parse.
  case totpCode(ItemReference)

  /// Reads the 851-2428 agent-access settings (``AgentSettings``) straight from the helper's own
  /// storage — never from the shared, any-process-writable `AppSettings` `UserDefaults` suite; see
  /// `AgentSettingsStoring`. Restricted to the app itself, same as ``createVault``/``unlock``, and
  /// — like those two — never reaches the access log: this is helper configuration, not a vault
  /// operation on a user's items.
  case getAgentSettings

  /// Replaces the 851-2428 agent-access settings. Restricted to the app itself, same as
  /// ``getAgentSettings``. The Settings → Agents UI is the only writer.
  case setAgentSettings(AgentSettings)

  /// 851-2441: every live item whose website matches one of `serviceIdentifiers` (a host match —
  /// see `PasswordItem.matchesHost(of:)` — against each identifier parsed as a URL), reduced to
  /// ``CredentialIdentity`` — service/website and username only, **never** the password. Powers
  /// the AutoFill credential provider extension's `prepareCredentialList(for:)`, which needs to
  /// show a relevant, searchable list without ever handing the extension a full ``PasswordItem``.
  /// Restricted to the AutoFill extension's verified connection (`AgentServer.isAutoFillCaller(_:)`);
  /// see `AgentError.callerNotAuthorized`. Deliberately **not** reachable by `lilpass` or the app —
  /// both already have `.list`/`.search` for the same data plus everything else on a `PasswordItem`.
  case autoFillIdentities(serviceIdentifiers: [String])

  /// 851-2441: the single username+password to fill for one identity, by the vault item id
  /// `ASCredentialIdentityStore` was given when that identity was registered
  /// (`ASPasswordCredentialIdentity.recordIdentifier`, set to `PasswordItem.id.uuidString`).
  /// Deliberately narrower than ``getItem(_:)``: this is the *only* operation that can ever hand
  /// the AutoFill extension a password, and it can never return a title, website, notes, or TOTP
  /// secret alongside it — the wire type (`AgentResponse.autoFillCredential`) makes that structural,
  /// not just a policy choice. Restricted to the AutoFill extension's verified connection, same as
  /// ``autoFillIdentities(serviceIdentifiers:)``. Fails with ``AgentError/notFound`` if `id` doesn't
  /// match a live item.
  case autoFillCredential(id: UUID)

  /// The 851-2445 "ask every time" approval queue: every request currently parked in
  /// `ApprovalCenter` awaiting a decision. Restricted to the app itself, same as
  /// ``getAgentSettings``/``setAgentSettings``, and — like those two — never reaches the access
  /// log; see docs/adr/0005-scoped-agent-access.md.
  case pendingApprovals

  /// Answers one pending approval (by the id `PendingApprovalSummary.id` handed back from
  /// ``pendingApprovals``) with the person's decision from the 851-2445 Touch ID-gated system
  /// dialog. Restricted to the app itself, same as ``pendingApprovals``.
  case resolveApproval(id: UUID, decision: ApprovalDecision)

  /// Whether this is `.generatePassword` — the one vault-adjacent request `AgentServer` exempts
  /// from 851-2445's `AgentAccessScope.askEveryTime` approval gate, since it never reads or writes
  /// any existing item and so has nothing an approval dialog could meaningfully describe (there's
  /// no item title, and "wants to generate a password" isn't a decision worth interrupting someone
  /// for). See docs/adr/0005-scoped-agent-access.md.
  public var isGeneratePassword: Bool {
    if case .generatePassword = self { return true }
    return false
  }
}

/// A vault item's identity for AutoFill purposes (851-2441): enough to render one row in the
/// credential provider's picker and to register with `ASCredentialIdentityStore` — service/website
/// and username — and **never** the password. Kept as its own type, distinct from `PasswordItem`,
/// specifically so `AgentResponse.autoFillIdentities` cannot carry a password no matter how
/// `PasswordItem` itself grows later.
public struct CredentialIdentity: Sendable, Codable, Equatable, Identifiable {
  public var id: UUID
  public var title: String
  public var username: String
  public var website: URL?

  public init(id: UUID, title: String, username: String, website: URL?) {
    self.id = id
    self.title = title
    self.username = username
    self.website = website
  }
}

/// How Settings → Agents' 851-2445 access-mode picker currently gates non-app callers
/// (`lilpass`/MCP) — mutually exclusive, unlike ``AgentSettings/agentAccessEnabled``/
/// ``AgentSettings/agentWriteAccessEnabled``, which are independent flags. See
/// docs/adr/0005-scoped-agent-access.md for the full design, including why `.selected` and
/// `.askEveryTime` are alternatives rather than stackable.
public enum AgentAccessScope: String, Sendable, Codable, Equatable, CaseIterable {
  /// Today's (pre-851-2445) behavior: every non-app caller with ``AgentSettings/agentAccessEnabled``
  /// sees every item. The default, and what every `AgentSettings` item stored before this ticket
  /// decodes to — see ``AgentSettings/init(from:)``.
  case allPasswords

  /// Only items whose id is in ``AgentSettings/allowedItemIDs`` or whose group is in
  /// ``AgentSettings/allowedGroups`` are visible to a non-app caller; everything else behaves as
  /// `AgentError.notFound`, never a distinguishable "forbidden" — see
  /// docs/adr/0005-scoped-agent-access.md's "No existence leak" section.
  case selected

  /// Every vault operation except ``AgentRequest/generatePassword(_:)`` blocks on a live,
  /// `LAContext`-gated approval from the app before proceeding — see ``ApprovalDecision``,
  /// ``PendingApprovalSummary``, and docs/adr/0005-scoped-agent-access.md's "Approval flow"
  /// section.
  case askEveryTime

  /// Plain-English label, for non-UI call sites (the access log's future use, debug/tophat
  /// descriptions) that just need a readable name and aren't rendered through SwiftUI. This package
  /// has no String Catalog of its own — the same reason `AppSettings.AutoLockInterval.displayName`
  /// returns unlocalized text — so it's deliberately *not* used by `AgentsSettingsView`'s picker;
  /// that view builds its own `Text("literal")` per case instead, so each option is a
  /// `LocalizedStringKey` the App target's `Localizable.xcstrings` actually extracts and localizes.
  public var displayName: String {
    switch self {
    case .allPasswords: "All Passwords"
    case .selected: "Only Selected Passwords"
    case .askEveryTime: "Ask Every Time"
    }
  }
}

/// A person's answer to one 851-2445 approval prompt, sent back via
/// ``AgentRequest/resolveApproval(id:decision:)``.
public enum ApprovalDecision: Sendable, Codable, Equatable {
  /// Allow just the one request that's currently parked awaiting this decision.
  case allowOnce

  /// Allow this request, and — per docs/adr/0005-scoped-agent-access.md's "Agent identity for
  /// grants" — skip the prompt for any further request from the same top-level agent
  /// (`AgentGrantIdentity`) for the next 15 minutes.
  case allowFor15Minutes

  /// Deny this request. Indistinguishable, by design, from a timeout — see
  /// ``AgentError/approvalDeniedOrTimedOut``.
  case deny
}

/// Everything the app's 851-2445 approval dialog needs to render one pending request — carries no
/// secret: not the requested item's password, only its title (if the item could be resolved before
/// the prompt was raised).
public struct PendingApprovalSummary: Sendable, Codable, Equatable, Identifiable {
  public var id: UUID
  public var requestedAt: Date

  /// A short, human-readable name for the requesting agent (e.g. `"claude"`) — the top-level
  /// entry of the resolved process chain, not a raw pid. See
  /// `CallerIdentityResolver.resolveTopLevelAgentIdentity(pid:maxDepth:)`.
  public var agentDescription: String

  /// The title of the item this request concerns, if one could be resolved — `nil` for operations
  /// with no single target (`.list`/`.search`/`.generatePassword`, the last of which never reaches
  /// this prompt at all).
  public var itemTitle: String?

  /// A human description of what's being requested, e.g. `"wants to read the password for"` —
  /// combined with ``agentDescription``/``itemTitle`` by the app's dialog to render something like
  /// `"claude (via lilpass) wants to read the password for GitHub"`.
  public var operationDescription: String

  public init(
    id: UUID = UUID(),
    requestedAt: Date = Date(),
    agentDescription: String,
    itemTitle: String?,
    operationDescription: String
  ) {
    self.id = id
    self.requestedAt = requestedAt
    self.agentDescription = agentDescription
    self.itemTitle = itemTitle
    self.operationDescription = operationDescription
  }
}

/// The 851-2428 "Allow agents to access passwords" toggle, its "keep agent access available while
/// the Mac is unlocked" nuance, and the 851-2433 "Allow agents to create, edit, and delete
/// passwords" write-access toggle — persisted **helper-side** (`AgentSettingsStoring`), read and
/// written exclusively through ``AgentRequest/getAgentSettings``/``AgentRequest/setAgentSettings(_:)``,
/// both restricted to the app's own, code-signing-verified connection
/// (`CallerIdentity.isVerifiedApp(appBundleIdentifier:)`).
///
/// Deliberately **not** stored in `AppSettings`'s shared `UserDefaults` suite the way the app's
/// other preferences are: that suite is, by design, freely writable by any local process that
/// knows its name (`defaults write com.851labs.lilpasswords.shared ...`), which would let an agent
/// silently flip its own access back on. See docs/adr/0001-storage-and-process-model.md (e) for
/// the full reasoning and the alternative (sealing these in the vault's own metadata) that was
/// considered and rejected.
///
/// **851-2433 fold-in**: `agentWriteAccessEnabled` used to live in its own, near-duplicate
/// helper-owned Keychain item (`AgentWriteAccessStoring`/`KeychainAgentWriteAccessStore`), read and
/// written through a separate `getAgentWriteAccessEnabled`/`setAgentWriteAccessEnabled` XPC pair,
/// while this struct and its real `getAgentSettings`/`setAgentSettings` ops (851-2428) were still
/// in review. Now that both have landed, write access is just a third field here, sharing this
/// struct's one Keychain item/ACL and one XPC pair — see `AgentServer.requireWriteAccess(for:)` for
/// where it's enforced.
public struct AgentSettings: Sendable, Codable, Equatable {
  /// Settings → Agents → "Allow agents to access passwords".
  public var agentAccessEnabled: Bool

  /// Settings → Agents → "Keep agent access available while the Mac is unlocked" — a policy nuance
  /// separate from the app's own auto-lock.
  public var keepAgentAccessAvailableWhileMacUnlocked: Bool

  /// Settings → Agents → "Allow agents to create, edit, and delete passwords" (851-2433) — a
  /// separate, narrower toggle than ``agentAccessEnabled``. Meaningless on its own: a caller only
  /// ever gets write access when this **and** ``agentAccessEnabled`` are both on — see
  /// `AgentServer.requireWriteAccess(for:)`, which only runs once the read-access check has
  /// already passed, so a non-app caller with read access off always sees
  /// `AgentError.agentAccessDisabled`, never `.agentWriteAccessDisabled`, regardless of this
  /// field's value. Defaults to `false`, matching this struct's overall fail-closed philosophy —
  /// an agent never gains the ability to modify a vault just because this field was left
  /// unspecified.
  public var agentWriteAccessEnabled: Bool

  /// Settings → Agents' 851-2445 access-mode picker. Defaults to ``AgentAccessScope/allPasswords``
  /// — today's behavior — both for freshly constructed settings and for any item stored before
  /// this ticket; see ``init(from:)``.
  public var accessScope: AgentAccessScope

  /// The allowlist ``AgentAccessScope/selected`` filters against, by item id. Ignored by the other
  /// two scopes. See docs/adr/0005-scoped-agent-access.md's "No existence leak" section.
  public var allowedItemIDs: Set<UUID>

  /// The allowlist ``AgentAccessScope/selected`` filters against, by `PasswordItem.group`. Ignored
  /// by the other two scopes.
  public var allowedGroups: Set<String>

  public init(
    agentAccessEnabled: Bool,
    keepAgentAccessAvailableWhileMacUnlocked: Bool,
    agentWriteAccessEnabled: Bool = false,
    accessScope: AgentAccessScope = .allPasswords,
    allowedItemIDs: Set<UUID> = [],
    allowedGroups: Set<String> = []
  ) {
    self.agentAccessEnabled = agentAccessEnabled
    self.keepAgentAccessAvailableWhileMacUnlocked = keepAgentAccessAvailableWhileMacUnlocked
    self.agentWriteAccessEnabled = agentWriteAccessEnabled
    self.accessScope = accessScope
    self.allowedItemIDs = allowedItemIDs
    self.allowedGroups = allowedGroups
  }

  private enum CodingKeys: String, CodingKey {
    case agentAccessEnabled
    case keepAgentAccessAvailableWhileMacUnlocked
    case agentWriteAccessEnabled
    case accessScope
    case allowedItemIDs
    case allowedGroups
  }

  /// A custom, rather than synthesized, `Decodable` conformance so a Keychain item written before
  /// 851-2433 added ``agentWriteAccessEnabled``, or before 851-2445 added ``accessScope``/
  /// ``allowedItemIDs``/``allowedGroups`` (no such keys in its stored JSON at all), still decodes
  /// instead of throwing — falling back to `false`/``AgentAccessScope/allPasswords``/empty sets,
  /// the same fail-closed-to-"no new restriction implied" defaults each field's own documentation
  /// promises, rather than treating a pre-851-2445 item as corrupt.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    agentAccessEnabled = try container.decode(Bool.self, forKey: .agentAccessEnabled)
    keepAgentAccessAvailableWhileMacUnlocked = try container.decode(
      Bool.self,
      forKey: .keepAgentAccessAvailableWhileMacUnlocked
    )
    agentWriteAccessEnabled = try container.decodeIfPresent(Bool.self, forKey: .agentWriteAccessEnabled) ?? false
    accessScope = try container.decodeIfPresent(AgentAccessScope.self, forKey: .accessScope) ?? .allPasswords
    allowedItemIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .allowedItemIDs) ?? []
    allowedGroups = try container.decodeIfPresent(Set<String>.self, forKey: .allowedGroups) ?? []
  }

  /// The fail-closed default: every reader of a stored `AgentSettings` — `AgentServer`,
  /// `AgentSettingsAccessPolicy` — falls back to this whenever the underlying store has nothing
  /// persisted yet, or fails to read at all (a corrupt item, an unexpected Keychain error). Agent
  /// access is never silently treated as enabled just because it couldn't be confirmed disabled.
  /// `accessScope` stays `.allPasswords` here — irrelevant while `agentAccessEnabled` is `false`,
  /// and keeping it at the "no restriction configured" default means this fail-closed struct never
  /// implies a scope decision that was never actually made.
  public static let disabled = AgentSettings(
    agentAccessEnabled: false,
    keepAgentAccessAvailableWhileMacUnlocked: false,
    agentWriteAccessEnabled: false,
    accessScope: .allPasswords,
    allowedItemIDs: [],
    allowedGroups: []
  )
}

/// A generated TOTP code and when it stops being valid, so a caller can decide whether to
/// re-request before pasting a stale code.
public struct TOTPCodeResult: Sendable, Codable, Equatable {
  public var code: String
  public var expiresAt: Date

  public init(code: String, expiresAt: Date) {
    self.code = code
    self.expiresAt = expiresAt
  }
}

/// Point-in-time answer to ``AgentRequest/status``.
public struct AgentStatus: Sendable, Codable, Equatable {
  /// `true` if the helper is holding no vault key (either never unlocked, or explicitly locked).
  public var locked: Bool

  /// The 851-2428 Settings toggle's current value ("Allow agents to access passwords"),
  /// independent of `locked` — both must be satisfied for a vault operation to succeed.
  public var agentAccessEnabled: Bool

  /// Whether a vault has ever been created at this helper's database. Lets the app distinguish
  /// "first run — no vault yet" (show vault setup) from "vault exists, currently locked" (show
  /// the 851-2422 lock screen) without attempting, and failing, an `.unlock` first.
  public var vaultExists: Bool

  public init(locked: Bool, agentAccessEnabled: Bool, vaultExists: Bool = true) {
    self.locked = locked
    self.agentAccessEnabled = agentAccessEnabled
    self.vaultExists = vaultExists
  }
}

/// A successful answer to an `AgentRequest`. Exactly one case per request case, in the same order.
public enum AgentResponse: Sendable, Codable, Equatable {
  case status(AgentStatus)
  /// Answers `.createVault`: the freshly created vault's recovery key, rendered the same
  /// human-transcribable way `VaultCrypto.RecoveryKey.displayString` always is. This is the app's
  /// only chance to see it — nothing else in the protocol ever hands it back.
  case vaultCreated(recoveryKeyDisplayString: String)
  case unlocked
  case locked
  /// Answers `.rotateRecoveryKey`: the newly generated recovery key, rendered for display — the
  /// app's only chance to see it, the same as `.vaultCreated`.
  case recoveryKeyRotated(recoveryKeyDisplayString: String)
  case items([PasswordItem])
  case item(PasswordItem)
  case created(PasswordItem)
  case updated(PasswordItem)
  case deleted
  case generatedPassword(String)
  case totpCode(TOTPCodeResult)
  /// Answers both ``AgentRequest/getAgentSettings`` and ``AgentRequest/setAgentSettings(_:)`` — a
  /// set always echoes back the settings that actually ended up persisted (mirroring `.created`/
  /// `.updated` echoing the item as stored), so a caller never has to issue a separate get right
  /// after a set to confirm what took effect.
  case agentSettings(AgentSettings)
  /// Answers ``AgentRequest/autoFillIdentities(serviceIdentifiers:)``.
  case autoFillIdentities([CredentialIdentity])
  /// Answers ``AgentRequest/autoFillCredential(id:)``. Exactly the two fields needed to build an
  /// `ASPasswordCredential` — nothing else about the item.
  case autoFillCredential(username: String, password: String)
  /// Answers ``AgentRequest/pendingApprovals``.
  case pendingApprovals([PendingApprovalSummary])
  /// Answers ``AgentRequest/resolveApproval(id:decision:)``.
  case approvalResolved
}

/// Every way an `AgentRequest` can fail, as a typed, `Codable` value rather than an opaque string
/// — so `AgentClient` callers (the app's UI, `lilpass`'s exit codes per 851-2428) can switch on the
/// reason instead of pattern-matching error text.
public enum AgentError: Error, Sendable, Codable, Equatable, CustomStringConvertible {
  /// The helper holds no vault key. The caller (app) needs to unlock via `LAContext` and call
  /// ``AgentRequest/unlock(_:)``.
  case locked

  /// The vault is unlocked, but the user has turned off "Allow agents to access passwords" in
  /// Settings → Agents (851-2428). Distinct from `.locked` because the fix is different (flip a
  /// setting, not authenticate).
  case agentAccessDisabled

  /// The vault and agent read access are both available, but the caller tried to create, update,
  /// or delete an item while "Allow agents to create, edit, and delete passwords" is off in
  /// Settings → Agents (851-2433) — a separate, narrower toggle than ``agentAccessEnabled``. Never
  /// thrown for the app's own connection, only for other callers (`lilpass`/MCP).
  case agentWriteAccessDisabled

  /// An `ItemReference` (or a plain id) matched no item.
  case notFound

  /// An `ItemReference.query` matched more than one item.
  case ambiguous

  /// The request's `AgentRequestEnvelope.version` isn't one this helper build understands. The
  /// MVP doesn't attempt partial compatibility across versions — a mismatch is always a hard
  /// error, on the theory that the app, `LilPasswordsAgent`, and `lilpass` are always built and
  /// shipped from the same repo/version and a mismatch only happens during development (an old
  /// helper still running after an app rebuild) or a bug, neither of which benefits from silently
  /// degrading.
  case unsupportedProtocolVersion(requested: Int, supported: Int)

  /// The connecting process isn't allowed to make this request — currently only reachable for
  /// `.createVault`/`.unlock`, both restricted to the app itself (never `lilpass`), since only the
  /// app performs the `LAContext` authentication that's supposed to gate them. See
  /// `AgentServer`'s caller check for how the app is told apart from any other peer.
  case callerNotAuthorized

  /// Anything else. `message` is always safe to log or display — it must never be built from a
  /// secret value (a vault item's password, the vault key, etc.); see call sites in
  /// `AgentServer`.
  case `internal`(message: String)

  /// The caller was subject to ``AgentAccessScope/askEveryTime`` and either the person explicitly
  /// denied the request, or nobody responded to the approval prompt within the ~60 second timeout
  /// — the two are indistinguishable by design; see docs/adr/0005-scoped-agent-access.md's
  /// "Approval flow" section. Maps to `LilpassExitCode.approvalDeniedOrTimedOut` (9).
  case approvalDeniedOrTimedOut

  public var description: String {
    switch self {
    case .locked:
      return "lil passwords is locked — unlock the app"
    case .agentAccessDisabled:
      return "agent access is disabled in Settings → Agents"
    case .agentWriteAccessDisabled:
      return "agent write access is disabled in Settings → Agents"
    case .notFound:
      return "no matching item"
    case .ambiguous:
      return "more than one item matched"
    case .unsupportedProtocolVersion(let requested, let supported):
      return "unsupported agent protocol version \(requested) (this helper supports \(supported))"
    case .callerNotAuthorized:
      return "this operation is only available to lil passwords itself"
    case .internal(let message):
      return message
    case .approvalDeniedOrTimedOut:
      return "approval denied or timed out"
    }
  }
}

/// The outcome of a single request: exactly one of a success payload or a typed error, `Codable`
/// as a two-case enum rather than `Swift.Result` (which has no `Codable` conformance).
public enum AgentOutcome: Sendable, Codable, Equatable {
  case success(AgentResponse)
  case failure(AgentError)
}

/// A request plus the protocol version it was built against. `AgentClient` always sends
/// ``AgentProtocolVersion/current``; the `version` field exists so `AgentServer` can detect a
/// mismatch explicitly instead of failing to decode.
public struct AgentRequestEnvelope: Sendable, Codable, Equatable {
  public var version: Int
  public var request: AgentRequest

  public init(request: AgentRequest, version: Int = AgentProtocolVersion.current) {
    self.version = version
    self.request = request
  }
}

/// The reply to an `AgentRequestEnvelope`, tagged with the protocol version the helper answered
/// with (currently always ``AgentProtocolVersion/current``, since a version mismatch is always an
/// error rather than a downgraded response — see `AgentError.unsupportedProtocolVersion`).
public struct AgentReplyEnvelope: Sendable, Codable, Equatable {
  public var version: Int
  public var outcome: AgentOutcome

  public init(outcome: AgentOutcome, version: Int = AgentProtocolVersion.current) {
    self.version = version
    self.outcome = outcome
  }
}

/// The single `JSONEncoder`/`JSONDecoder` configuration `AgentClient` and `AgentServer` must
/// agree on to decode each other's `Data`. Centralized so the two sides can't silently drift
/// (e.g. one adding a date strategy the other doesn't have).
public enum AgentWireCoding {
  public static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  public static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
