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
  private let accessPolicy: any AccessPolicyProviding
  private let accessLog: any AccessLogging
  private let passwordGenerator: PasswordGenerator

  /// - Parameter vaultStore: The single `VaultStoring` this helper serves for its entire process
  ///   lifetime. Injected (rather than `AgentServer` constructing a concrete `VaultStore` itself)
  ///   so production code and tests can supply different backends (`VaultStore` vs
  ///   `InMemoryVaultStore`) without `AgentServer` depending on either concrete type.
  public init(
    vaultStore: any VaultStoring,
    accessPolicy: any AccessPolicyProviding = AlwaysAllowAccessPolicy(),
    accessLog: any AccessLogging = NoOpAccessLog(),
    passwordGenerator: PasswordGenerator = PasswordGenerator()
  ) {
    self.vaultStore = vaultStore
    self.accessPolicy = accessPolicy
    self.accessLog = accessLog
    self.passwordGenerator = passwordGenerator
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
    case .status, .unlock, .lock:
      outcome = await lifecycleOutcome(for: envelope.request)
    default:
      outcome = await vaultOutcome(for: envelope.request, caller: caller)
    }
    return AgentReplyEnvelope(outcome: outcome)
  }

  // MARK: - Lock lifecycle (never logged — see AccessLogging)

  private func lifecycleOutcome(for request: AgentRequest) async -> AgentOutcome {
    switch request {
    case .status:
      let locked = await !vaultStore.isUnlocked
      let status = AgentStatus(locked: locked, agentAccessEnabled: await accessPolicy.isAgentAccessEnabled())
      return .success(.status(status))

    case .unlock(let payload):
      do {
        let key = try VaultCrypto.Key(id: payload.keyId, rawData: payload.sessionKey)
        try await vaultStore.open(with: key)
        return .success(.unlocked)
      } catch let error as AgentError {
        return .failure(error)
      } catch {
        return .failure(.internal(message: "\(error)"))
      }

    case .lock:
      await vaultStore.lock()
      return .success(.locked)

    default:
      preconditionFailure("lifecycleOutcome only handles .status/.unlock/.lock")
    }
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

    case .status, .unlock, .lock:
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
