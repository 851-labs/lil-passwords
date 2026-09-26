import Foundation

/// An async/await client for `LilPasswordsAgent`'s Mach service, used by both the app and
/// `lilpass`.
///
/// Owns at most one `NSXPCConnection`, created lazily on first use and torn down on invalidation
/// or interruption so the next call reconnects rather than reusing a dead connection.
public actor AgentClient {
  /// Where to connect: the real Mach service, or (for tests) a specific in-process listener
  /// endpoint.
  enum Target: Sendable {
    case machService(name: String)
    case endpoint(NSXPCListenerEndpoint)
  }

  /// Everything that can go wrong that isn't a typed `AgentError` from the helper itself.
  public enum ConnectionError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The connection was invalidated or interrupted (the helper crashed, was killed, or failed
    /// the code-signing requirement) before a reply arrived.
    case invalidated(reason: String)
    /// The reply `Data` didn't decode as an `AgentReplyEnvelope`, or a response arrived that
    /// wasn't the case a given call expected.
    case invalidReply

    public var description: String {
      switch self {
      case .invalidated(let reason): return "the connection to LilPasswordsAgent was invalidated (\(reason))"
      case .invalidReply: return "LilPasswordsAgent sent a reply that couldn't be decoded"
      }
    }
  }

  /// A request either failed to reach/return from the helper (``ConnectionError``), or the helper
  /// answered with a typed ``AgentError``.
  public enum RequestError: Error, Sendable, CustomStringConvertible {
    case connection(ConnectionError)
    case remote(AgentError)

    public var description: String {
      switch self {
      case .connection(let error): return error.description
      case .remote(let error): return error.description
      }
    }
  }

  private let target: Target
  private let connectionSecurity: AgentConnectionSecurity.Requirement
  private var connection: NSXPCConnection?

  /// Connects to the real, launchd-activated Mach service, validating that the peer is really
  /// `LilPasswordsAgent` (see `AgentConnectionSecurity`).
  public init(machServiceName: String = AgentXPC.machServiceName) {
    self.target = .machService(name: machServiceName)
    self.connectionSecurity = AgentConnectionSecurity.requirement(acceptingPeers: [.agent])
  }

  /// Connects to a specific listener endpoint (e.g. from `NSXPCListener.anonymous()`), for
  /// in-process end-to-end tests. An in-process peer is the test binary itself, which can't
  /// satisfy a real team+identifier check, so callers must supply `connectionSecurity` explicitly
  /// rather than getting one derived from the running process's own signature.
  init(endpoint: NSXPCListenerEndpoint, connectionSecurity: AgentConnectionSecurity.Requirement) {
    self.target = .endpoint(endpoint)
    self.connectionSecurity = connectionSecurity
  }

  public func status() async throws -> AgentStatus {
    guard case .status(let status) = try await send(.status) else { throw RequestError.connection(.invalidReply) }
    return status
  }

  /// First run: asks the helper to generate a fresh vault key, create the vault, and persist the
  /// key to the local Keychain. Returns the new vault's recovery key, rendered for display — the
  /// app's only chance to show it (see `AgentResponse.vaultCreated`). Restricted to the app itself
  /// by the helper; see `AgentError.callerNotAuthorized`.
  @discardableResult
  public func createVault() async throws -> String {
    guard case .vaultCreated(let recoveryKeyDisplayString) = try await send(.createVault) else {
      throw RequestError.connection(.invalidReply)
    }
    return recoveryKeyDisplayString
  }

  /// Sends an unlock **intent** — no key material at all. The app calls this after its
  /// `LAContext` evaluation succeeds; the helper reads the vault key itself from the local
  /// Keychain. See docs/adr/0001-storage-and-process-model.md (b) and `AgentRequest.unlock`.
  public func unlock() async throws {
    guard case .unlocked = try await send(.unlock) else {
      throw RequestError.connection(.invalidReply)
    }
  }

  public func lock() async throws {
    guard case .locked = try await send(.lock) else { throw RequestError.connection(.invalidReply) }
  }

  /// Regenerates the vault's recovery key: the helper generates a new `VaultCrypto.RecoveryKey`,
  /// re-wraps the current vault key under it, and replaces the wrapped copy in `meta` — the
  /// previous recovery key stops working immediately. Returns the new recovery key, rendered for
  /// display — the app's only chance to show it (see `AgentResponse.recoveryKeyRotated`).
  /// Restricted to the app itself by the helper; see `AgentError.callerNotAuthorized`. The caller
  /// is expected to perform `LAContext` authentication before sending this, the same as before
  /// `.unlock`.
  @discardableResult
  public func rotateRecoveryKey() async throws -> String {
    guard case .recoveryKeyRotated(let recoveryKeyDisplayString) = try await send(.rotateRecoveryKey) else {
      throw RequestError.connection(.invalidReply)
    }
    return recoveryKeyDisplayString
  }

  public func list() async throws -> [PasswordItem] {
    guard case .items(let items) = try await send(.list) else { throw RequestError.connection(.invalidReply) }
    return items
  }

  public func search(_ query: String) async throws -> [PasswordItem] {
    guard case .items(let items) = try await send(.search(query: query)) else {
      throw RequestError.connection(.invalidReply)
    }
    return items
  }

  public func item(_ reference: ItemReference) async throws -> PasswordItem {
    guard case .item(let item) = try await send(.getItem(reference)) else {
      throw RequestError.connection(.invalidReply)
    }
    return item
  }

  @discardableResult
  public func create(_ item: PasswordItem) async throws -> PasswordItem {
    guard case .created(let created) = try await send(.createItem(item)) else {
      throw RequestError.connection(.invalidReply)
    }
    return created
  }

  @discardableResult
  public func update(_ item: PasswordItem) async throws -> PasswordItem {
    guard case .updated(let updated) = try await send(.updateItem(item)) else {
      throw RequestError.connection(.invalidReply)
    }
    return updated
  }

  public func delete(_ reference: ItemReference) async throws {
    guard case .deleted = try await send(.deleteItem(reference)) else { throw RequestError.connection(.invalidReply) }
  }

  public func generatePassword(format: PasswordGenerator.Format = .appleStrong) async throws -> String {
    guard case .generatedPassword(let password) = try await send(.generatePassword(format)) else {
      throw RequestError.connection(.invalidReply)
    }
    return password
  }

  public func totpCode(_ reference: ItemReference) async throws -> TOTPCodeResult {
    guard case .totpCode(let result) = try await send(.totpCode(reference)) else {
      throw RequestError.connection(.invalidReply)
    }
    return result
  }

  /// Reads the 851-2428 agent-access settings straight from the helper's own storage. Restricted
  /// to the app itself by the helper; see `AgentError.callerNotAuthorized`.
  public func agentSettings() async throws -> AgentSettings {
    guard case .agentSettings(let settings) = try await send(.getAgentSettings) else {
      throw RequestError.connection(.invalidReply)
    }
    return settings
  }

  /// Replaces the 851-2428 agent-access settings. Restricted to the app itself, same as
  /// ``agentSettings()``. Returns the settings as the helper actually persisted them.
  @discardableResult
  public func setAgentSettings(_ settings: AgentSettings) async throws -> AgentSettings {
    guard case .agentSettings(let updated) = try await send(.setAgentSettings(settings)) else {
      throw RequestError.connection(.invalidReply)
    }
    return updated
  }

  /// 851-2441: every live item whose website matches one of `serviceIdentifiers`, narrowed to just
  /// `CredentialIdentity` (never a password) — powers the AutoFill extension's
  /// `prepareCredentialList(for:)`. Restricted to the AutoFill extension's own verified connection
  /// by the helper; see `AgentServer.isRequestPermitted(_:for:)`.
  public func autoFillIdentities(serviceIdentifiers: [String]) async throws -> [CredentialIdentity] {
    let request = AgentRequest.autoFillIdentities(serviceIdentifiers: serviceIdentifiers)
    guard case .autoFillIdentities(let identities) = try await send(request) else {
      throw RequestError.connection(.invalidReply)
    }
    return identities
  }

  /// 851-2441: the username+password for exactly one item id — nothing else about the item is ever
  /// returned. Powers `provideCredentialWithoutUserInteraction(for:)`/
  /// `prepareInterfaceToProvideCredential(for:)`. Restricted to the AutoFill extension's own
  /// verified connection by the helper; throws `AgentError.locked` while the vault is locked (see
  /// `ASExtensionError.userInteractionRequired` at the call site).
  public func autoFillCredential(id: UUID) async throws -> (username: String, password: String) {
    guard case .autoFillCredential(let username, let password) = try await send(.autoFillCredential(id: id)) else {
      throw RequestError.connection(.invalidReply)
    }
    return (username, password)
  }

  /// The 851-2445 "ask every time" approval queue: every request currently parked in the helper's
  /// `ApprovalCenter` awaiting a decision, oldest first. Restricted to the app itself by the
  /// helper, same as ``agentSettings()``. The app polls or calls this on
  /// ``AgentApprovalObserver``'s wake-up to drive its Touch ID-gated approval dialog.
  public func pendingApprovals() async throws -> [PendingApprovalSummary] {
    guard case .pendingApprovals(let summaries) = try await send(.pendingApprovals) else {
      throw RequestError.connection(.invalidReply)
    }
    return summaries
  }

  /// Answers one pending approval (by the id `PendingApprovalSummary.id` handed back from
  /// ``pendingApprovals()``) with the person's decision from the approval dialog. Restricted to
  /// the app itself, same as ``pendingApprovals()``. A no-op on the helper side if `id` is no
  /// longer pending (already resolved, already timed out); this still returns normally either way.
  public func resolveApproval(id: UUID, decision: ApprovalDecision) async throws {
    guard case .approvalResolved = try await send(.resolveApproval(id: id, decision: decision)) else {
      throw RequestError.connection(.invalidReply)
    }
  }

  /// Tears down the current connection, if any. The next call reconnects. Not required in normal
  /// use (interruption/invalidation already clear it), but useful for tests and for explicit
  /// "log out" style flows.
  public func invalidate() {
    connection?.invalidate()
    connection = nil
  }

  // MARK: - Wire plumbing

  private func send(_ request: AgentRequest) async throws -> AgentResponse {
    let requestData: Data
    do {
      requestData = try AgentWireCoding.encoder.encode(AgentRequestEnvelope(request: request))
    } catch {
      throw RequestError.connection(.invalidReply)
    }

    let replyData = try await sendOverXPC(requestData)

    let envelope: AgentReplyEnvelope
    do {
      envelope = try AgentWireCoding.decoder.decode(AgentReplyEnvelope.self, from: replyData)
    } catch {
      throw RequestError.connection(.invalidReply)
    }

    switch envelope.outcome {
    case .success(let response): return response
    case .failure(let error): throw RequestError.remote(error)
    }
  }

  private func sendOverXPC(_ data: Data) async throws -> Data {
    // Fail closed, symmetrically with the helper side (`AgentXPCListenerDelegate`): a Release
    // build with no team identifier can't verify it's really talking to `LilPasswordsAgent`
    // rather than some other same-user process that squatted the Mach service name, so refuse to
    // even attempt the connection rather than exchanging data with an unverified peer.
    if case .rejectAll(let reason) = connectionSecurity {
      throw RequestError.connection(.invalidated(reason: reason))
    }
    let connection = activeConnection()
    do {
      return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            continuation.resume(throwing: ConnectionError.invalidated(reason: error.localizedDescription))
          }) as? AgentXPCProtocol
        else {
          continuation.resume(throwing: ConnectionError.invalidated(reason: "no remote object proxy"))
          return
        }
        proxy.send(data) { replyData in
          continuation.resume(returning: replyData)
        }
      }
    } catch let error as ConnectionError {
      throw RequestError.connection(error)
    } catch {
      throw RequestError.connection(.invalidated(reason: "\(error)"))
    }
  }

  private func activeConnection() -> NSXPCConnection {
    if let connection { return connection }

    let newConnection: NSXPCConnection
    switch target {
    case .machService(let name):
      newConnection = NSXPCConnection(machServiceName: name, options: [])
    case .endpoint(let endpoint):
      newConnection = NSXPCConnection(listenerEndpoint: endpoint)
    }

    newConnection.remoteObjectInterface = NSXPCInterface(with: AgentXPCProtocol.self)
    switch connectionSecurity {
    case .enforce(let requirement):
      newConnection.setCodeSigningRequirement(requirement)
    case .developmentFallback:
      break
    case .rejectAll:
      // Unreachable in practice: `sendOverXPC` throws before ever calling `activeConnection()`
      // for `.rejectAll`. Handled here anyway so this switch stays exhaustive without a `default`.
      break
    }
    // Unwrap `self` to a strong local *before* handing it to `Task { }`: capturing the raw `weak
    // self` inside the nested `Task` closure (rather than a materialized strong reference) is what
    // the older Swift/Xcode toolchain CI builds with flags as "passing closure as a 'sending'
    // parameter risks causing data races" — a weak reference can be nilled out concurrently by ARC,
    // so it isn't a safe value to hand across the isolation boundary `Task.init`'s `sending`
    // closure parameter introduces, even though the referent (`AgentClient`, an actor) is `Sendable`
    // once loaded. `guard let self` loads it once into an immutable, genuinely `Sendable` local
    // that both toolchains accept.
    newConnection.invalidationHandler = { [weak self] in
      guard let self else { return }
      Task { await self.clearConnection() }
    }
    newConnection.interruptionHandler = { [weak self] in
      guard let self else { return }
      Task { await self.clearConnection() }
    }
    newConnection.resume()
    connection = newConnection
    return newConnection
  }

  private func clearConnection() {
    connection = nil
  }
}
