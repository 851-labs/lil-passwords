import Foundation

/// The single `@objc` entry point `LilPasswordsAgent`'s Mach service exposes.
///
/// XPC method signatures must be `@objc`-compatible (arguments/returns that are `NSSecureCoding`,
/// or primitives), which would normally force the rich `AgentRequest`/`AgentResponse` enums in
/// `AgentProtocol.swift` down into something much flatter. Sending them pre-encoded as `Data`
/// (via `AgentWireCoding`) sidesteps that entirely: this is the only method XPC ever sees, and
/// every future operation is just a new `AgentRequest` case, never a new method here.
@objc public protocol AgentXPCProtocol {
  func send(_ requestData: Data, reply: @escaping @Sendable (Data) -> Void)
}

/// Constants shared by the listener (`LilPasswordsAgent`) and every client (`AgentClient`).
public enum AgentXPC {
  /// The Mach service name launchd registers for `LilPasswordsAgent`. Must match the
  /// `MachServices` key in `Agent/Support/com.851labs.lilpasswords.agent.plist`.
  public static let machServiceName = "com.851labs.lilpasswords.agent.xpc"
}
