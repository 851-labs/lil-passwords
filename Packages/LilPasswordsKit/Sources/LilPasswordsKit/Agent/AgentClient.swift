import Foundation

/// An async/await client for `LilPasswordsAgent`'s Mach service, used by both the app and
/// `lilpw`.
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

  /// Hands the vault key to the helper. The app calls this after its `LAContext` evaluation
  /// succeeds — see docs/adr/0001-storage-and-process-model.md (b).
  public func unlock(sessionKey: Data, keyId: UUID) async throws {
    guard case .unlocked = try await send(.unlock(UnlockPayload(sessionKey: sessionKey, keyId: keyId))) else {
      throw RequestError.connection(.invalidReply)
    }
  }

  public func lock() async throws {
    guard case .locked = try await send(.lock) else { throw RequestError.connection(.invalidReply) }
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
    }
    newConnection.invalidationHandler = { [weak self] in
      Task { await self?.clearConnection() }
    }
    newConnection.interruptionHandler = { [weak self] in
      Task { await self?.clearConnection() }
    }
    newConnection.resume()
    connection = newConnection
    return newConnection
  }

  private func clearConnection() {
    connection = nil
  }
}
