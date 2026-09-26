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
/// AppSettings-backed conformer there is the only change 851-2428 should need to make here.
public struct AlwaysDenyAccessPolicy: AccessPolicyProviding {
  public init() {}
  public func isAgentAccessEnabled() async -> Bool { false }
}

/// The real, 851-2428 access policy: reads Settings → Agents → "Allow agents to access passwords"
/// live from `AppSettings`, with one exemption for the app's own connection.
///
/// "Live" here just means reading `AppSettings` again on every call rather than caching a value at
/// init — `UserDefaults(suiteName:)` already keeps the app's, the helper's, and `lilpw`'s view of
/// the shared suite in sync across processes (it's backed by the same on-disk plist/`cfprefsd`), so
/// no separate KVO/notification plumbing is needed for the helper to see a toggle flipped from the
/// Settings window a moment earlier. (Something does need to _re-read_ per request, though — a
/// value captured once at helper-launch time would never see later changes — which is what makes
/// this a struct with computed properties rather than a class that reads `AppSettings` once at
/// `init`.)
///
/// The app's own XPC connection is exempt from this toggle: the toggle exists to gate *agents*
/// (`lilpw`, the MCP server, anything scripting against the vault), not the app whose Settings
/// window the toggle lives in — a user who's turned agent access off has not asked their own app's
/// item list/detail views to stop working. `AgentConnectionSecurity.requirement(acceptingPeers:)`
/// only ever accepts connections from exactly two code-signed peers (`.app`, `.cli`; see its
/// documentation), so by the time a `CallerIdentity` reaches here it is guaranteed to be one or the
/// other — ``isAppCaller(_:)`` only has to tell those two apart, not defend against an arbitrary
/// process.
public struct AppSettingsAccessPolicy: AccessPolicyProviding {
  private let settings: AppSettings
  private let isAppCaller: @Sendable (CallerIdentity) -> Bool

  /// - Parameter isAppCaller: Overridable for tests. Defaults to ``defaultIsAppCaller(_:)``.
  public init(
    settings: AppSettings = .shared,
    isAppCaller: @escaping @Sendable (CallerIdentity) -> Bool = AppSettingsAccessPolicy.defaultIsAppCaller
  ) {
    self.settings = settings
    self.isAppCaller = isAppCaller
  }

  public func isAgentAccessEnabled() async -> Bool {
    settings.agentAccessEnabled
  }

  public func isAccessAllowed(for caller: CallerIdentity) async -> Bool {
    if isAppCaller(caller) { return true }
    return settings.agentAccessEnabled
  }

  /// Settings → Agents → "Keep agent access available while the Mac is unlocked" (read live, same
  /// as ``isAgentAccessEnabled()``). Nothing reads this yet: there's no separate "the app itself
  /// has auto-locked but the Mac hasn't" timer to gate agent access on until 851-2411 lands.
  /// Exposing it here means 851-2411 only has to read it from this policy instead of re-deriving
  /// it from `AppSettings` a second way, and it's covered by ``AppSettingsAccessPolicyTests``
  /// today so it doesn't silently rot before then.
  public var keepAgentAccessAvailableWhileMacUnlocked: Bool {
    settings.keepAgentAccessAvailableWhileMacUnlocked
  }

  /// Best-effort "is this the app itself, not `lilpw`" check, using only what `CallerIdentity`
  /// already resolves: the last path component of the caller's own executable, compared against
  /// ``LilPasswordsKit/productName``. `lilpw`'s executable is named after
  /// ``LilPasswordsKit/cliName`` instead, and the app bundle's Mach-O is always named after the
  /// product (`Lil Passwords.app/Contents/MacOS/Lil Passwords`), so this is exact for the two peers
  /// `AgentConnectionSecurity` ever accepts — it doesn't need to be a general-purpose sniff test.
  /// Falls back to `false` (treat as an agent, the more restrictive answer) if the path couldn't be
  /// resolved at all, e.g. the caller has already exited.
  public static func defaultIsAppCaller(_ caller: CallerIdentity) -> Bool {
    guard let processPath = caller.processPath else { return false }
    return (processPath as NSString).lastPathComponent == LilPasswordsKit.productName
  }
}
