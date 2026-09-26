import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct CallerIdentityResolverTests {
  @Test func resolvingTheCurrentProcessFindsItsOwnPathAndAParentProcessName() {
    let identity = CallerIdentityResolver.resolve(pid: ProcessInfo.processInfo.processIdentifier)

    #expect(identity.pid == ProcessInfo.processInfo.processIdentifier)
    // The test binary is a real, running executable, so `proc_pidpath` should resolve it.
    #expect(identity.processPath != nil)
    #expect(identity.processPath?.isEmpty == false)
    // Every process except pid 1 has a parent; the test runner is never pid 1.
    #expect(identity.parentProcessName != nil)
  }

  @Test func resolvingAnImplausiblePidFailsGracefullyInsteadOfCrashing() {
    // pid_t is a 32-bit signed integer; this value is picked to almost certainly not correspond
    // to any running process, without being a sentinel like -1 that some libproc calls special-case.
    let identity = CallerIdentityResolver.resolve(pid: pid_t.max)

    #expect(identity.pid == pid_t.max)
    #expect(identity.processPath == nil)
    #expect(identity.parentProcessName == nil)
  }

  /// 851-2411 (post-review): resolving from a real `NSXPCConnection`'s audit token, rather than
  /// its bare pid, should land on the exact same identity for a same-process connection — this is
  /// the same in-process `NSXPCListener.anonymous()` pattern `AgentXPCEndToEndTests`/`AgentServer`
  /// harnesses use, so it also exercises the actual code path `AgentXPCListenerDelegate` calls in
  /// production, not a hand-rolled fake.
  ///
  /// A real round trip through `CallerIdentityProbePinging` is required: an `NSXPCListener` only
  /// actually invokes `shouldAcceptNewConnection` once a peer attempts real communication, not
  /// merely from `resume()` on either side — resolving inside that callback, as
  /// `AgentXPCListenerDelegate` itself does, guarantees the underlying connection (and its audit
  /// token) is already established by the time this code reads it.
  @Test func resolvingFromAConnectionMatchesResolvingFromItsBarePid() async throws {
    final class Delegate: NSObject, NSXPCListenerDelegate {
      var resolvedIdentity: CallerIdentity?

      func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: CallerIdentityProbePinging.self)
        newConnection.exportedObject = CallerIdentityProbePingObject()
        newConnection.resume()
        resolvedIdentity = CallerIdentityResolver.resolve(connection: newConnection)
        return true
      }
    }

    let listener = NSXPCListener.anonymous()
    let delegate = Delegate()
    listener.delegate = delegate
    listener.resume()
    defer { listener.invalidate() }

    let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
    connection.remoteObjectInterface = NSXPCInterface(with: CallerIdentityProbePinging.self)
    connection.resume()
    defer { connection.invalidate() }

    let proxy = connection.remoteObjectProxy as! CallerIdentityProbePinging
    await withCheckedContinuation { continuation in
      proxy.ping { continuation.resume() }
    }

    let identity = try #require(delegate.resolvedIdentity)
    let ownPid = ProcessInfo.processInfo.processIdentifier
    let expected = CallerIdentityResolver.resolve(pid: ownPid)

    #expect(identity.pid == ownPid)
    // Same process on both ends of an in-process connection, so the audit-token-resolved identity
    // must land on the exact same bundle identifier the pid-based path already resolves — proving
    // the audit-token path isn't silently falling back to `nil`/a different identity.
    #expect(identity.bundleIdentifier == expected.bundleIdentifier)
    #expect(identity.bundleIdentifier != nil)
  }

  /// An audit token of all zeros doesn't identify any real running guest, so resolving it should
  /// fail gracefully to `nil` rather than crash or resolve to a bogus identity — mirroring
  /// ``resolvingAnImplausiblePidFailsGracefullyInsteadOfCrashing()`` for the pid-based path.
  @Test func resolvingAnAllZeroAuditTokenFailsGracefullyInsteadOfCrashing() {
    let identity = CallerIdentityResolver.resolve(auditToken: audit_token_t(), pid: pid_t.max)

    #expect(identity.pid == pid_t.max)
    #expect(identity.bundleIdentifier == nil)
  }
}

/// A minimal `@objc` protocol purely to force a real round trip over an in-process
/// `NSXPCConnection`/`NSXPCListener.anonymous()` pair — see
/// `resolvingFromAConnectionMatchesResolvingFromItsBarePid()`'s doc comment for why that's needed
/// before resolving a connection's audit token. Declared at file scope: `NSXPCInterface(with:)`
/// requires a real Objective-C protocol, which Swift can't declare nested inside a function/type.
@objc private protocol CallerIdentityProbePinging {
  func ping(reply: @escaping () -> Void)
}

private final class CallerIdentityProbePingObject: NSObject, CallerIdentityProbePinging {
  func ping(reply: @escaping () -> Void) {
    reply()
  }
}
