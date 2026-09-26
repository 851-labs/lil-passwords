import Foundation

/// Whether `LilPasswordsAgent` should currently serve vault operations to agents (`lilpw`/MCP),
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

/// The default policy: agent access is always enabled. Used by `LilPasswordsAgent` until
/// 851-2428 lands, and by tests that don't care about the toggle.
public struct AlwaysAllowAccessPolicy: AccessPolicyProviding {
  public init() {}
  public func isAgentAccessEnabled() async -> Bool { true }
}
