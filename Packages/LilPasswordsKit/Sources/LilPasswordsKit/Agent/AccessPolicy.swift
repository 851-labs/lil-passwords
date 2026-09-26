import Foundation

/// Whether `LilPasswordsAgent` should currently serve vault operations to agents (`lilpass`/MCP),
/// independent of lock state.
///
/// **Seam**: the Settings → Agents → "Allow agents to access passwords" toggle and its storage
/// are 851-2428, including the "keep agent access available while the Mac is unlocked" variant
/// described there. `AgentServer` only ever calls ``isAgentAccessEnabled()`` and throws
/// `AgentError.agentAccessDisabled` when it returns `false`; 851-2428 supplies the real conformer
/// without `AgentServer` changing at all.
public protocol AccessPolicyProviding: Sendable {
  func isAgentAccessEnabled() async -> Bool

  /// Whether `caller` specifically may perform a vault operation right now.
  ///
  /// Defaults to mirroring ``isAgentAccessEnabled()`` for every caller, so every conformer written
  /// before this method existed (`AlwaysAllowAccessPolicy`/`AlwaysDenyAccessPolicy` below, and
  /// tests' own fakes) keeps compiling and behaving exactly as before without any changes.
  /// 851-2428's ``AppSettingsAccessPolicy`` overrides this to add its one caller-specific
  /// exemption: the app's own XPC connection is never subject to this toggle, because it's the UI
  /// the toggle lives in, not an agent.
  func isAccessAllowed(for caller: CallerIdentity) async -> Bool
}

extension AccessPolicyProviding {
  public func isAccessAllowed(for caller: CallerIdentity) async -> Bool {
    await isAgentAccessEnabled()
  }
}

/// `AgentServer`'s own default parameter value, for tests (and any other caller) that don't care
/// about the toggle and just want the vault operations they're testing to always be reachable.
///
/// **Not** what `Agent/Sources/main.swift` wires up in production — see ``AlwaysDenyAccessPolicy``
/// for that. `AgentServer` keeping this as its *parameter* default only affects callers that don't
/// pass `accessPolicy` explicitly, which in practice today is exactly the test suites; production
/// always passes one explicitly.
public struct AlwaysAllowAccessPolicy: AccessPolicyProviding {
  public init() {}
  public func isAgentAccessEnabled() async -> Bool { true }
}

/// The production default until 851-2428 lands: agent access is always **disabled**.
///
/// `LilPasswordsAgent` (`Agent/Sources/main.swift`) wires this in explicitly rather than relying
/// on `AgentServer`'s own `AlwaysAllowAccessPolicy()` parameter default, so a real user's vault is
/// never reachable through the helper before they've explicitly turned agent access on — during
/// onboarding or in Settings, once 851-2428 exists to do either. Swapping in the real,
/// `AgentSettingsAccessPolicy` conformer there is the only change 851-2428 should need to make
/// here.
public struct AlwaysDenyAccessPolicy: AccessPolicyProviding {
  public init() {}
  public func isAgentAccessEnabled() async -> Bool { false }
}

/// The real, 851-2428 access policy: reads Settings → Agents → "Allow agents to access passwords"
/// live from the helper-owned ``AgentSettingsStoring`` store, with one exemption for the app's own
/// connection.
///
/// "Live" here just means reading `store` again on every call rather than caching a value at init
/// — the store already keeps the helper's own, authoritative view of the setting (it's the only
/// writer, via `AgentServer`'s `.setAgentSettings`), so no separate KVO/notification plumbing is
/// needed. (Something does need to _re-read_ per request, though — a value captured once at
/// helper-launch time would never see a later `.setAgentSettings` — which is what makes this a
/// struct with computed properties rather than a class that reads the store once at `init`.)
///
/// The app's own XPC connection is exempt from this toggle: the toggle exists to gate *agents*
/// (`lilpass`, the MCP server, anything scripting against the vault), not the app whose Settings
/// window the toggle lives in — a user who's turned agent access off has not asked their own app's
/// item list/detail views to stop working. 851-2441's AutoFill credential provider extension is
/// exempt for the same reason but a different justification: it's not a background agent either —
/// every connection from it is directly triggered by the user picking "lil passwords" in the
/// system AutoFill UI, which itself requires unlocking the Mac/authenticating, so there's no
/// scenario where turning agent access off should also turn off Safari/system AutoFill. (It's still
/// far more restricted than the app — see `AgentServer.isRequestPermitted(_:for:)` — this exemption
/// only concerns the 851-2428 toggle, not what operations it can reach at all.)
/// `AgentConnectionSecurity.requirement(acceptingPeers:)` only ever accepts connections from
/// exactly three code-signed peers (`.app`, `.cli`, `.autoFill`; see its documentation), so by the
/// time a `CallerIdentity` reaches here it is guaranteed to be one of those three —
/// ``isAppCaller(_:)``/``isAutoFillCaller(_:)`` only have to tell them apart, not defend against an
/// arbitrary process.
///
/// **Security history (851-2428 review):** this type used to be named `AppSettingsAccessPolicy` and
/// read `AppSettings.agentAccessEnabled`/`.keepAgentAccessAvailableWhileMacUnlocked` straight out of
/// the shared, any-process-writable `UserDefaults` suite, and its own-connection exemption
/// (`defaultIsAppCaller`) compared the caller's `processPath` — a plain, spoofable string — against
/// the product name. Both were security bugs: any local process could flip the toggle back on with
/// `defaults write`, and `cp lilpass "/tmp/lil passwords"` could impersonate the app. Both are fixed
/// here: settings are read from a helper-owned ``AgentSettingsStoring`` store instead (see that
/// protocol and docs/adr/0001-storage-and-process-model.md (e)), and `defaultIsAppCaller` now
/// delegates to `CallerIdentity.isVerifiedApp(appBundleIdentifier:)`, the same
/// code-signing-verified check `AgentServer.isAppCaller(_:)` uses.
public struct AgentSettingsAccessPolicy: AccessPolicyProviding {
  private let store: any AgentSettingsStoring
  private let isAppCaller: @Sendable (CallerIdentity) -> Bool
  private let isAutoFillCaller: @Sendable (CallerIdentity) -> Bool

  /// - Parameters:
  ///   - store: Where the 851-2428 settings actually live — required, with no default, since a
  ///     policy silently defaulting to some store here could too easily paper over production
  ///     wiring forgetting to share the same instance `AgentServer` writes through.
  ///   - isAppCaller: Overridable for tests. Defaults to ``defaultIsAppCaller(_:)``.
  ///   - isAutoFillCaller: Overridable for tests. Defaults to ``defaultIsAutoFillCaller(_:)``.
  public init(
    store: any AgentSettingsStoring,
    isAppCaller: @escaping @Sendable (CallerIdentity) -> Bool = AgentSettingsAccessPolicy.defaultIsAppCaller,
    isAutoFillCaller: @escaping @Sendable (CallerIdentity) -> Bool = AgentSettingsAccessPolicy.defaultIsAutoFillCaller
  ) {
    self.store = store
    self.isAppCaller = isAppCaller
    self.isAutoFillCaller = isAutoFillCaller
  }

  public func isAgentAccessEnabled() async -> Bool {
    currentSettings().agentAccessEnabled
  }

  public func isAccessAllowed(for caller: CallerIdentity) async -> Bool {
    if isAppCaller(caller) || isAutoFillCaller(caller) { return true }
    return currentSettings().agentAccessEnabled
  }

  /// Settings → Agents → "Keep agent access available while the Mac is unlocked" (read live, same
  /// as ``isAgentAccessEnabled()``). Nothing reads this yet: there's no separate "the app itself
  /// has auto-locked but the Mac hasn't" timer to gate agent access on until 851-2411 lands.
  /// Exposing it here means 851-2411 only has to read it from this policy instead of re-deriving
  /// it a second way, and it's covered by ``AgentSettingsAccessPolicyTests`` today so it doesn't
  /// silently rot before then.
  public var keepAgentAccessAvailableWhileMacUnlocked: Bool {
    currentSettings().keepAgentAccessAvailableWhileMacUnlocked
  }

  /// Fails closed: any read failure or "never stored yet" is treated as `.disabled`, never
  /// silently as enabled. Shared with `AgentServer` via ``AgentSettings/loaded(from:)`` so the two
  /// can't independently get the fallback wrong.
  private func currentSettings() -> AgentSettings {
    AgentSettings.loaded(from: store)
  }

  /// The verified, shared "is this the app itself, not `lilpass`" check — see
  /// `CallerIdentity.isVerifiedApp(appBundleIdentifier:)` for the full reasoning, including why a
  /// prior, separate implementation of this exact check (comparing `caller.processPath`, a
  /// spoofable string, against the product name) was a security bug this delegation fixes.
  public static func defaultIsAppCaller(_ caller: CallerIdentity) -> Bool {
    caller.isVerifiedApp()
  }

  /// The 851-2441 counterpart to ``defaultIsAppCaller(_:)``: verified via the same
  /// `CallerIdentity.isVerifiedApp(appBundleIdentifier:)`, just with the AutoFill extension's own
  /// bundle identifier. Unlike `AgentServer.isAutoFillCaller(_:)` (which deliberately does *not* use
  /// this method, for a *restrictive* check — see that method's documentation), this one only ever
  /// *grants* an exemption, so falling back to the DEBUG "no resolvable bundle identifier" behavior
  /// `isVerifiedApp` already has is safe here: it can only make an unsigned local/CI build's caller
  /// exempt from the 851-2428 toggle too, never lock anything out.
  public static func defaultIsAutoFillCaller(_ caller: CallerIdentity) -> Bool {
    caller.isVerifiedApp(appBundleIdentifier: AgentConnectionSecurity.PeerIdentifier.autoFill.rawValue)
  }
}
