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

  /// An unlock **intent**, carrying no key material at all: the app performs `LAContext`
  /// authentication (Touch ID/Apple Watch/login password) first, then sends this so the helper
  /// reads the vault key itself from the local Keychain (`VaultKeyStoring`) and opens the store.
  /// The key never leaves the helper process — see docs/adr/0001-storage-and-process-model.md (b).
  /// Restricted to the app itself, the same as `.createVault`, and authenticated by the
  /// connection's code-signing requirement rather than anything in this payload.
  case unlock

  /// Discards the in-memory vault key and any open store. Idempotent.
  case lock

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
}

/// The 851-2428 "Allow agents to access passwords" toggle and its "keep agent access available
/// while the Mac is unlocked" nuance — persisted **helper-side** (`AgentSettingsStoring`), read and
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
public struct AgentSettings: Sendable, Codable, Equatable {
  /// Settings → Agents → "Allow agents to access passwords".
  public var agentAccessEnabled: Bool

  /// Settings → Agents → "Keep agent access available while the Mac is unlocked" — a policy nuance
  /// separate from the app's own auto-lock.
  public var keepAgentAccessAvailableWhileMacUnlocked: Bool

  public init(agentAccessEnabled: Bool, keepAgentAccessAvailableWhileMacUnlocked: Bool) {
    self.agentAccessEnabled = agentAccessEnabled
    self.keepAgentAccessAvailableWhileMacUnlocked = keepAgentAccessAvailableWhileMacUnlocked
  }

  /// The fail-closed default: every reader of a stored `AgentSettings` — `AgentServer`,
  /// `AgentSettingsAccessPolicy` — falls back to this whenever the underlying store has nothing
  /// persisted yet, or fails to read at all (a corrupt item, an unexpected Keychain error). Agent
  /// access is never silently treated as enabled just because it couldn't be confirmed disabled.
  public static let disabled = AgentSettings(
    agentAccessEnabled: false,
    keepAgentAccessAvailableWhileMacUnlocked: false
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

  public var description: String {
    switch self {
    case .locked:
      return "lil passwords is locked — unlock the app"
    case .agentAccessDisabled:
      return "agent access is disabled in Settings → Agents"
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
