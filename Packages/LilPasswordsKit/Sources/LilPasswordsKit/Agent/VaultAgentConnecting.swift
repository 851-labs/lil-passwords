import Foundation

/// The subset of `AgentClient` that `LockCoordinator` needs — status, first-run vault creation,
/// unlock, and lock. Exists so tests can drive `LockCoordinator` against a fake rather than a
/// real `NSXPCConnection`, the same seam pattern as `VaultAuthenticating`/`VaultKeyStoring`
/// elsewhere in this package.
public protocol VaultAgentConnecting: Sendable {
  func status() async throws -> AgentStatus

  @discardableResult
  func createVault() async throws -> String

  func unlock() async throws

  func lock() async throws
}

extension AgentClient: VaultAgentConnecting {}
