import Foundation

/// Accepts and validates incoming `NSXPCConnection`s for `LilPasswordsAgent`'s Mach service, and
/// wires each accepted connection to a fresh ``AgentExportedObject`` bound to that connection's
/// caller identity.
///
/// Usable both for the real, launchd-activated Mach service (`NSXPCListener(machServiceName:)` in
/// `Agent/Sources/main.swift`) and for in-process tests (`NSXPCListener.anonymous()`), since
/// neither the delegate nor `AgentServer` know or care which kind of listener they're attached to.
public final class AgentXPCListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
  private let server: AgentServer
  private let connectionSecurity: AgentConnectionSecurity.Requirement

  /// - Parameter connectionSecurity: Typically `AgentConnectionSecurity.requirement(acceptingPeers:)`
  ///   in production. Tests pass `.developmentFallback` (an in-process peer is the test binary
  ///   itself, which can't satisfy a real team+identifier check) or a fabricated `.enforce` string
  ///   to exercise rejection.
  public init(server: AgentServer, connectionSecurity: AgentConnectionSecurity.Requirement) {
    self.server = server
    self.connectionSecurity = connectionSecurity
  }

  public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
    switch connectionSecurity {
    case .enforce(let requirement):
      // If the peer doesn't satisfy this, the system invalidates the connection itself once it's
      // used — see `AgentConnectionSecurity` for why this can't itself throw a catchable error.
      newConnection.setCodeSigningRequirement(requirement)
    case .developmentFallback(let reason):
      FileHandle.standardError.write(
        Data(
          "LilPasswordsAgent: accepting an XPC connection without code-signature validation (\(reason))\n".utf8
        )
      )
    }

    let caller = CallerIdentityResolver.resolve(pid: newConnection.processIdentifier)
    let exportedObject = AgentExportedObject(server: server, caller: caller)
    newConnection.exportedInterface = NSXPCInterface(with: AgentXPCProtocol.self)
    newConnection.exportedObject = exportedObject
    newConnection.resume()
    return true
  }
}

/// The `@objc` object actually vended to each connection. Decodes the single `send(_:reply:)`
/// call's `Data` into an `AgentRequestEnvelope`, dispatches it to `AgentServer` with this
/// connection's captured `CallerIdentity`, and encodes the reply back to `Data`.
final class AgentExportedObject: NSObject, AgentXPCProtocol {
  private let server: AgentServer
  private let caller: CallerIdentity

  init(server: AgentServer, caller: CallerIdentity) {
    self.server = server
    self.caller = caller
  }

  func send(_ requestData: Data, reply: @escaping @Sendable (Data) -> Void) {
    let server = server
    let caller = caller
    Task {
      let replyEnvelope: AgentReplyEnvelope
      do {
        let envelope = try AgentWireCoding.decoder.decode(AgentRequestEnvelope.self, from: requestData)
        replyEnvelope = await server.handle(envelope, caller: caller)
      } catch {
        // A request that doesn't even decode can't carry a meaningful `version`, so this doesn't
        // go through `AgentError.unsupportedProtocolVersion` — it's a malformed message, not a
        // version mismatch.
        replyEnvelope = AgentReplyEnvelope(outcome: .failure(.internal(message: "malformed request: \(error)")))
      }
      reply((try? AgentWireCoding.encoder.encode(replyEnvelope)) ?? Data())
    }
  }
}
