import Foundation

/// The app-side lock state, as `MainWindowController` (851-2422) should present it.
///
/// This is deliberately a small, closed set rather than something that also tries to model
/// connection failures in general: a dropped XPC connection while `.unlocked` or `.locked`
/// surfaces as `.unlockFailed`'s message the next time the user (or auto-refresh) tries to act,
/// rather than as a distinct "disconnected" case — see `LockCoordinator.refresh()`.
public enum LockState: Sendable, Equatable {
  /// Initial state, and the state while `refresh()` is awaiting `AgentClient.status()`.
  case checking
  /// No vault exists yet (`AgentStatus.vaultExists == false`) — first run. The app should show
  /// its first-run flow (851-2447's recovery kit sheet, or a stub until that lands) rather than
  /// the 851-2422 lock screen.
  case needsVaultSetup
  case locked
  case unlocked
  /// A `unlock()` attempt failed — either the `LAContext` evaluation itself (Touch ID/password
  /// cancelled or failed) or the subsequent XPC call to the helper. See `UnlockFailure` for how
  /// this is meant to be rendered under the lock screen's subtitle.
  case unlockFailed(UnlockFailure)
}

/// Drives the app-side lock/unlock state machine described by 851-2411 and 851-2422: asks
/// `VaultAgentConnecting` (a real `AgentClient` in production) for the helper's current lock
/// state, evaluates `VaultAuthenticating` (a real `LAContext` in production) before sending an
/// unlock intent, and republishes the result as `LockState` for `MainWindowController` to render.
///
/// An actor so state reads/writes and the async calls that produce them are naturally
/// serialized — two overlapping `unlock()` calls (e.g. a user mashing the "Use Password…" button)
/// can't race each other into an inconsistent `state`.
///
/// Tests drive this against fakes for both dependencies (`VaultAgentConnecting`,
/// `VaultAuthenticating`) — see `LockCoordinatorTests` — rather than a real `AgentClient`/
/// `LAContext`, which is what satisfies this ticket's "tests for the lock state machine (inject
/// the LAContext and clock)" requirement on the app side (`AutoLockEngineTests` covers the
/// clock-injection half, on the helper side).
public actor LockCoordinator {
  public private(set) var state: LockState = .checking

  private let agent: any VaultAgentConnecting
  private let authenticator: any VaultAuthenticating
  private var subscribers: [Int: AsyncStream<LockState>.Continuation] = [:]
  private var nextToken = 0

  public init(agent: any VaultAgentConnecting, authenticator: any VaultAuthenticating) {
    self.agent = agent
    self.authenticator = authenticator
  }

  /// A stream of every subsequent state change (not the current state — read `state` directly for
  /// that before subscribing, to avoid missing the transition between the two).
  public func stateChanges() -> AsyncStream<LockState> {
    let (stream, continuation) = AsyncStream<LockState>.makeStream()
    let token = nextToken
    nextToken += 1
    subscribers[token] = continuation

    continuation.onTermination = { [weak self] _ in
      guard let self else { return }
      Task { await self.removeSubscriber(token) }
    }

    return stream
  }

  /// Asks the helper for its current status and updates `state` to match — `.needsVaultSetup` if
  /// no vault exists yet, otherwise `.locked`/`.unlocked` per `AgentStatus.locked`. Called on
  /// launch, and again whenever `LockStateObserver` fires (the helper's lock state changed for a
  /// reason this process didn't initiate itself — auto-lock, or another client's `.lock()`).
  public func refresh() async {
    do {
      let status = try await agent.status()
      if !status.vaultExists {
        setState(.needsVaultSetup)
      } else if status.locked {
        setState(.locked)
      } else {
        setState(.unlocked)
      }
    } catch {
      setState(.unlockFailed(.describing(error)))
    }
  }

  /// First run: asks the helper to generate and store a new vault key and create the vault.
  /// Returns the recovery key's display string — the app's only chance to show it before handing
  /// off to the recovery kit sheet (851-2447) or its stub.
  @discardableResult
  public func setUpVault() async throws -> String {
    do {
      let recoveryKeyDisplayString = try await agent.createVault()
      setState(.unlocked)
      return recoveryKeyDisplayString
    } catch {
      setState(.unlockFailed(.describing(error)))
      throw error
    }
  }

  /// Evaluates device-owner authentication, then — only if that succeeds — sends the unlock
  /// intent. Moves to `.unlocked` on success, `.unlockFailed` on either step failing (the
  /// `LAContext` evaluation itself, or the subsequent helper round trip).
  public func unlock(reason: String = "Unlock \(LilPasswordsKit.productName)") async {
    do {
      try await authenticator.authenticateDeviceOwner(reason: reason)
      try await agent.unlock()
      setState(.unlocked)
    } catch {
      setState(.unlockFailed(.describing(error)))
    }
  }

  /// Locks immediately, with no `LAContext` involved — this is what the "Lock Now" menu item
  /// (851-2424) and a manual re-lock affordance call.
  public func lock() async {
    do {
      try await agent.lock()
      setState(.locked)
    } catch {
      setState(.unlockFailed(.describing(error)))
    }
  }

  private func setState(_ newState: LockState) {
    state = newState
    for continuation in subscribers.values {
      continuation.yield(newState)
    }
  }

  private func removeSubscriber(_ token: Int) {
    subscribers.removeValue(forKey: token)
  }
}
