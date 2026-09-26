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
