import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct LockCoordinatorTests {
  /// A fake `VaultAgentConnecting` whose every response is scripted up front, so tests don't need
  /// a real `AgentClient`/`NSXPCConnection` (that's what `AgentXPCEndToEndTests` is for) to drive
  /// `LockCoordinator`'s state machine.
  ///
  /// A plain lock-protected class rather than an actor: `VaultAgentConnecting`'s methods are
  /// already `async`, so there's no isolation benefit to also making this type an actor — and
  /// doing so would force every scripted-property read/write below behind `await`, for no benefit
  /// in a fake whose whole point is to be easy to poke from a test body.
  private final class FakeAgent: VaultAgentConnecting, @unchecked Sendable {
    enum ScriptedFailure: Error, Equatable {
      case createVault
      case unlock
      case lock
      case status
    }

    private let mutex = NSLock()
    private var _vaultExists: Bool
    private var _locked: Bool
    var recoveryKeyDisplayString = "4S9K-D2XQ-7RTN-8YCB-J3WM"
    var failStatus = false
    var failCreateVault = false
    var failUnlock = false
    var failLock = false

    private(set) var unlockCallCount = 0
    private(set) var lockCallCount = 0
    private(set) var createVaultCallCount = 0

    init(vaultExists: Bool, locked: Bool) {
      self._vaultExists = vaultExists
      self._locked = locked
    }

    func status() async throws -> AgentStatus {
      if failStatus { throw ScriptedFailure.status }
      return mutex.withLock { AgentStatus(locked: _locked, agentAccessEnabled: true, vaultExists: _vaultExists) }
    }

    func createVault() async throws -> String {
      createVaultCallCount += 1
      if failCreateVault { throw ScriptedFailure.createVault }
      mutex.withLock {
        _vaultExists = true
        _locked = false
      }
      return recoveryKeyDisplayString
    }

    func unlock() async throws {
      unlockCallCount += 1
      if failUnlock { throw ScriptedFailure.unlock }
      mutex.withLock { _locked = false }
    }

    func lock() async throws {
      lockCallCount += 1
      if failLock { throw ScriptedFailure.lock }
      mutex.withLock { _locked = true }
    }
  }

  @Test func refreshReportsNeedsVaultSetupWhenNoVaultExists() async {
    let agent = FakeAgent(vaultExists: false, locked: true)
    let coordinator = LockCoordinator(agent: agent, authenticator: AlwaysSucceedAuthenticator())

    #expect(await coordinator.state == .checking)
    await coordinator.refresh()
    #expect(await coordinator.state == .needsVaultSetup)
  }

  @Test func refreshReportsLockedWhenAVaultExistsButIsLocked() async {
    let agent = FakeAgent(vaultExists: true, locked: true)
    let coordinator = LockCoordinator(agent: agent, authenticator: AlwaysSucceedAuthenticator())

    await coordinator.refresh()
    #expect(await coordinator.state == .locked)
  }

  @Test func refreshReportsUnlockedWhenAVaultExistsAndIsUnlocked() async {
    let agent = FakeAgent(vaultExists: true, locked: false)
    let coordinator = LockCoordinator(agent: agent, authenticator: AlwaysSucceedAuthenticator())

    await coordinator.refresh()
    #expect(await coordinator.state == .unlocked)
  }

  @Test func refreshSurfacesAConnectionFailureAsUnlockFailed() async {
    let agent = FakeAgent(vaultExists: true, locked: true)
    agent.failStatus = true
    let coordinator = LockCoordinator(agent: agent, authenticator: AlwaysSucceedAuthenticator())

    await coordinator.refresh()
    guard case .unlockFailed = await coordinator.state else {
      Issue.record("expected .unlockFailed, got \(await coordinator.state)")
      return
    }
  }

  @Test func setUpVaultMovesToUnlockedAndReturnsTheRecoveryKey() async throws {
    let agent = FakeAgent(vaultExists: false, locked: true)
    let coordinator = LockCoordinator(agent: agent, authenticator: AlwaysSucceedAuthenticator())

    let recoveryKeyDisplayString = try await coordinator.setUpVault()
    #expect(recoveryKeyDisplayString == agent.recoveryKeyDisplayString)
    #expect(await coordinator.state == .unlocked)
    #expect(agent.createVaultCallCount == 1)
  }

  @Test func setUpVaultFailurePropagatesAndMovesToUnlockFailed() async {
    let agent = FakeAgent(vaultExists: false, locked: true)
    agent.failCreateVault = true
    let coordinator = LockCoordinator(agent: agent, authenticator: AlwaysSucceedAuthenticator())

    await #expect(throws: FakeAgent.ScriptedFailure.createVault) {
      try await coordinator.setUpVault()
    }
    guard case .unlockFailed = await coordinator.state else {
      Issue.record("expected .unlockFailed, got \(await coordinator.state)")
      return
    }
  }

  @Test func unlockEvaluatesDeviceOwnerAuthenticationBeforeSendingTheUnlockIntent() async {
    let agent = FakeAgent(vaultExists: true, locked: true)
    let coordinator = LockCoordinator(agent: agent, authenticator: AlwaysSucceedAuthenticator())

    await coordinator.unlock()
    #expect(await coordinator.state == .unlocked)
    #expect(agent.unlockCallCount == 1)
  }

  @Test func unlockNeverReachesTheHelperWhenLAContextEvaluationFails() async {
    // The whole point of doing device-owner auth in the app first (ADR 0001): a failed `LAContext`
    // evaluation must short-circuit before any unlock intent reaches the helper.
    let agent = FakeAgent(vaultExists: true, locked: true)
    let coordinator = LockCoordinator(agent: agent, authenticator: AlwaysFailAuthenticator())

    await coordinator.unlock()
    guard case .unlockFailed = await coordinator.state else {
      Issue.record("expected .unlockFailed, got \(await coordinator.state)")
      return
    }
    #expect(agent.unlockCallCount == 0)
  }

  @Test func unlockFailsWithUnlockFailedWhenTheHelperRejectsTheIntent() async {
    let agent = FakeAgent(vaultExists: true, locked: true)
    agent.failUnlock = true
    let coordinator = LockCoordinator(agent: agent, authenticator: AlwaysSucceedAuthenticator())

    await coordinator.unlock()
    guard case .unlockFailed = await coordinator.state else {
      Issue.record("expected .unlockFailed, got \(await coordinator.state)")
      return
    }
  }

  @Test func lockMovesToLockedWithoutAnyAuthentication() async {
    let agent = FakeAgent(vaultExists: true, locked: false)
    let coordinator = LockCoordinator(agent: agent, authenticator: AlwaysFailAuthenticator())

    await coordinator.lock()
    #expect(await coordinator.state == .locked)
  }

  @Test func stateChangesStreamsEverySubsequentTransition() async {
    let agent = FakeAgent(vaultExists: true, locked: true)
    let coordinator = LockCoordinator(agent: agent, authenticator: AlwaysSucceedAuthenticator())

    let stream = await coordinator.stateChanges()
    var iterator = stream.makeAsyncIterator()

    await coordinator.unlock()
    let first = await iterator.next()
    #expect(first == .unlocked)

    await coordinator.lock()
    let second = await iterator.next()
    #expect(second == .locked)
  }
}
