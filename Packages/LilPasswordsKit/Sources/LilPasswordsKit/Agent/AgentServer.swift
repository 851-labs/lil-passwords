import Foundation

/// The helper's request handler: dispatches every `AgentRequest` to its `VaultStoring`, the
/// access policy, and the access log.
///
/// Lock state itself lives in `vaultStore` (`VaultStoring.isUnlocked`/`open(with:)`/`lock()`),
/// not in `AgentServer` — one `VaultStoring` instance is constructed once (by
/// `Agent/Sources/main.swift` in production, by tests otherwise) and handed to this initializer,
/// matching "the helper owns the lock state" in this ticket's description: the vault key lives in
/// the store, which lives exactly as long as the helper process does.
///
/// One `AgentServer` instance is shared across every accepted `NSXPCConnection` — lock state is
/// process-wide, not per-connection. `CallerIdentity` (per-connection) is passed into
/// ``handle(_:caller:)`` by the caller (`AgentXPCListenerDelegate`/its exported object), not
/// stored here.
public actor AgentServer {
  private let vaultStore: any VaultStoring
  private let vaultKeyStore: any VaultKeyStoring
  private let accessPolicy: any AccessPolicyProviding
  private let accessLog: any AccessLogging
  private let passwordGenerator: PasswordGenerator
  private let appCallerBundleIdentifier: String

  /// - Parameters:
  ///   - vaultStore: The single `VaultStoring` this helper serves for its entire process
  ///     lifetime. Injected (rather than `AgentServer` constructing a concrete `VaultStore` itself)
  ///     so production code and tests can supply different backends (`VaultStore` vs
  ///     `InMemoryVaultStore`) without `AgentServer` depending on either concrete type.
  ///   - vaultKeyStore: Where `.createVault` persists the freshly generated vault key and
  ///     `.unlock` reads it back from — the local Keychain in production
  ///     (`KeychainVaultKeyStore`), an in-memory double in tests. Defaults to
  ///     `InMemoryVaultKeyStore()` purely so existing call sites that only care about the vault
  ///     CRUD surface (not lock lifecycle) don't all need updating; production wiring
  ///     (`Agent/Sources/main.swift`) always passes `KeychainVaultKeyStore()` explicitly.
  ///   - appCallerBundleIdentifier: The bundle identifier `isAppCaller(_:)` treats as "the app" for
  ///     `.createVault`/`.unlock` gating. Defaults to the real app's identifier
  ///     (`AgentConnectionSecurity.PeerIdentifier.app`). Overridable so an in-process XPC test
  ///     harness (`AgentXPCEndToEndTests`), whose connecting peer really is the test binary itself
  ///     — not an unsigned/ad-hoc process with no `bundleIdentifier` at all, but a normally-signed
  ///     one with *some* real, resolvable identifier (e.g. the `xctest` tool's) — can tell
  ///     `AgentServer` to trust that identifier as "the app" instead. This exercises the exact same
  ///     caller-identity-resolution and gating code production does; only which identifier counts
  ///     as trusted changes.
  public init(
    vaultStore: any VaultStoring,
    vaultKeyStore: any VaultKeyStoring = InMemoryVaultKeyStore(),
    accessPolicy: any AccessPolicyProviding = AlwaysAllowAccessPolicy(),
    accessLog: any AccessLogging = NoOpAccessLog(),
    passwordGenerator: PasswordGenerator = PasswordGenerator(),
    appCallerBundleIdentifier: String = AgentConnectionSecurity.PeerIdentifier.app.rawValue
  ) {
    self.vaultStore = vaultStore
    self.vaultKeyStore = vaultKeyStore
    self.accessPolicy = accessPolicy
    self.accessLog = accessLog
    self.passwordGenerator = passwordGenerator
    self.appCallerBundleIdentifier = appCallerBundleIdentifier
  }

  /// Handles one already-decoded request and returns the reply envelope to send back.
  ///
  /// `caller` is threaded through only as far as the access log (see `AccessLogging`'s docs for
  /// why lock-lifecycle requests never reach it).
  public func handle(_ envelope: AgentRequestEnvelope, caller: CallerIdentity) async -> AgentReplyEnvelope {
    guard envelope.version == AgentProtocolVersion.current else {
      return AgentReplyEnvelope(
        outcome: .failure(
          .unsupportedProtocolVersion(requested: envelope.version, supported: AgentProtocolVersion.current)
        )
      )
    }

    let outcome: AgentOutcome
    switch envelope.request {
    case .status, .createVault, .unlock, .lock:
      outcome = await lifecycleOutcome(for: envelope.request, caller: caller)
    default:
      outcome = await vaultOutcome(for: envelope.request, caller: caller)
    }
    return AgentReplyEnvelope(outcome: outcome)
  }

  // MARK: - Lock lifecycle (never logged — see AccessLogging)

  private func lifecycleOutcome(for request: AgentRequest, caller: CallerIdentity) async -> AgentOutcome {
    switch request {
    case .status:
      let locked = await !vaultStore.isUnlocked
      // A store that fails to answer `vaultExists()` (a corrupt/unreadable database, say) is
      // treated as "a vault exists" rather than "no vault yet": the former just means the app
      // shows the lock screen and a subsequent `.unlock` fails with a real error, while the
      // latter would offer to `.createVault` over — and silently orphan — whatever's actually on
      // disk.
      let exists = (try? await vaultStore.vaultExists()) ?? true
      let status = AgentStatus(
        locked: locked,
        agentAccessEnabled: await accessPolicy.isAgentAccessEnabled(),
        vaultExists: exists
      )
      return .success(.status(status))

    case .createVault:
      guard isAppCaller(caller) else { return .failure(.callerNotAuthorized) }
      do {
        let recoveryKey = try await vaultStore.createVault()
        let key = try await vaultStore.currentKey()
        try vaultKeyStore.store(key)
        LockStateNotifications.post()
        return .success(.vaultCreated(recoveryKeyDisplayString: recoveryKey.displayString))
      } catch let error as AgentError {
        return .failure(error)
      } catch let error as VaultStoreError {
        return .failure(agentError(for: error))
      } catch {
        return .failure(.internal(message: "\(error)"))
      }

    case .unlock:
      guard isAppCaller(caller) else { return .failure(.callerNotAuthorized) }
      do {
        guard let key = try vaultKeyStore.loadKey() else {
          // No key ever stored — either `.createVault` never ran (shouldn't happen; the app
          // always calls it on first run before offering to unlock anything) or something wiped
          // the Keychain item out from under this helper. Either way, the caller can't proceed by
          // retrying `.unlock` — surfaced as an `.internal` error rather than `.locked` (a bare
          // "wrong password" story) since there's no key material to even try.
          return .failure(.internal(message: "no vault key is stored — call .createVault first"))
        }
        try await vaultStore.open(with: key)
        LockStateNotifications.post()
        return .success(.unlocked)
      } catch let error as AgentError {
        return .failure(error)
      } catch let error as VaultStoreError {
        return .failure(agentError(for: error))
      } catch {
        return .failure(.internal(message: "\(error)"))
      }

    case .lock:
      await vaultStore.lock()
      LockStateNotifications.post()
      return .success(.locked)

    default:
      preconditionFailure("lifecycleOutcome only handles .status/.createVault/.unlock/.lock")
    }
  }

  /// Whether `caller` is allowed to send `.createVault`/`.unlock` — both restricted to the app
  /// itself, since only the app performs the `LAContext` authentication that's supposed to gate
  /// them (see docs/adr/0001-storage-and-process-model.md (b)). `lilpw`, or any other process,
  /// must never be able to trigger either just by connecting to the Mach service.
  ///
  /// Falls back to `AgentConnectionSecurity.isDebugBuild` when `caller.bundleIdentifier` is `nil`
  /// (an unsigned/ad-hoc local build, or the in-process XPC test harness, neither of which has a
  /// real code signature to read a bundle identifier from) — the same DEBUG-vs-Release philosophy
  /// `AgentConnectionSecurity` itself already applies at the whole-connection level, applied here
  /// too so this per-request check doesn't independently reject every local/CI build.
  private func isAppCaller(_ caller: CallerIdentity) -> Bool {
    guard let bundleIdentifier = caller.bundleIdentifier else {
      return AgentConnectionSecurity.isDebugBuild
    }
    return bundleIdentifier == appCallerBundleIdentifier
  }

  // MARK: - Vault operations (logged via AccessLogging)

  private func vaultOutcome(for request: AgentRequest, caller: CallerIdentity) async -> AgentOutcome {
    let outcome: AgentOutcome
    do {
      outcome = .success(try await vaultResponse(for: request))
    } catch let error as AgentError {
      outcome = .failure(error)
    } catch let error as VaultStoreError {
      outcome = .failure(agentError(for: error))
    } catch {
      outcome = .failure(.internal(message: "\(error)"))
    }

    let succeeded: Bool
    if case .success = outcome {
      succeeded = true
    } else {
      succeeded = false
    }
    await accessLog.record(AccessEvent(caller: caller, request: request, succeeded: succeeded))
    return outcome
  }

  private func vaultResponse(for request: AgentRequest) async throws -> AgentResponse {
    guard await accessPolicy.isAgentAccessEnabled() else { throw AgentError.agentAccessDisabled }
    guard await vaultStore.isUnlocked else { throw AgentError.locked }

    switch request {
    case .list:
      return .items(try await vaultStore.allItems().filter(isLive))

    case .search(let query):
      return .items(try await vaultStore.items(matching: query).filter(isLive))

    case .getItem(let reference):
      return .item(try await resolve(reference))

    case .createItem(let item):
      try await vaultStore.create(item)
      return .created(item)

    case .updateItem(let item):
      try await vaultStore.update(item)
      return .updated(item)

    case .deleteItem(let reference):
      let item = try await resolve(reference)
      try await vaultStore.delete(id: item.id)
      return .deleted

    case .generatePassword(let format):
      do {
        return .generatedPassword(try passwordGenerator.generate(format: format))
      } catch {
        throw AgentError.internal(message: "\(error)")
      }

    case .totpCode(let reference):
      let item = try await resolve(reference)
      guard let totp = item.totp else {
        throw AgentError.internal(message: "item has no usable TOTP secret")
      }
      let now = Date()
      return .totpCode(TOTPCodeResult(code: totp.code(at: now), expiresAt: totp.nextChange(after: now)))

    case .status, .createVault, .unlock, .lock:
      preconditionFailure("vaultResponse never sees lock-lifecycle requests")
    }
  }

  /// `VaultStoring` soft-deletes: `allItems()`/`item(id:)`/`items(matching:)` keep returning a
  /// deleted record (with `deletedAt` set) until the store's next reload — see
  /// `VaultStoreSharedBehaviorTests.assertCRUDLifecycle`'s "Soft delete" comment. `AgentServer`'s
  /// wire protocol has no notion of tombstones, so every vault operation filters them out here
  /// rather than leaking that storage-layer detail to `lilpw`/the app.
  private func isLive(_ item: PasswordItem) -> Bool {
    item.deletedAt == nil
  }

  private func resolve(_ reference: ItemReference) async throws -> PasswordItem {
    switch reference {
    case .id(let id):
      guard let item = try await vaultStore.item(id: id), isLive(item) else { throw AgentError.notFound }
      return item

    case .query(let query):
      let matches = try await vaultStore.items(matching: query).filter(isLive)
      guard let first = matches.first else { throw AgentError.notFound }
      guard matches.count == 1 else { throw AgentError.ambiguous }
      return first
    }
  }

  /// Translates a `VaultStoreError` into the typed, wire-safe `AgentError` a caller should see.
  /// Only cases with an obvious, already-existing `AgentError` counterpart get one
  /// (`.itemNotFound` → `.notFound`, `.locked` → `.locked`, the latter only reachable in a race
  /// between the `isUnlocked` check above and a concurrent `.lock` request); everything else
  /// (a corrupt database, an incorrect key, a future format version) is a condition this ticket's
  /// protocol has no dedicated case for, so it falls back to `.internal` — its message is always
  /// safe to log since `VaultStoreError`'s cases never carry vault secrets.
  private func agentError(for error: VaultStoreError) -> AgentError {
    switch error {
    case .itemNotFound:
      return .notFound
    case .locked:
      return .locked
    case .vaultAlreadyExists, .vaultNotFound, .incorrectKey, .itemAlreadyExists, .unsupportedVaultFormatVersion,
      .corruptData, .sqlite:
      return .internal(message: "\(error)")
    }
  }
}
