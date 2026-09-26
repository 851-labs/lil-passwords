import Darwin
import Foundation
import Security

/// Identifies the process on the other end of an accepted `NSXPCConnection`.
///
/// This is a **seam** for 851-2429 (the access log): `AgentXPCListenerDelegate` captures a
/// `CallerIdentity` once per connection (at accept time, from `NSXPCConnection.processIdentifier`)
/// and threads it through to `AgentServer`, which attaches it to every `AccessEvent`. 851-2429's
/// real logger can use `pid`/`processPath`/`parentProcessName` to render "which tool or command,
/// which process chain (e.g. claude, codex)" without either this type or `AgentServer` changing.
public struct CallerIdentity: Sendable, Equatable {
  /// The connecting process's pid, from `NSXPCConnection.processIdentifier`.
  public var pid: pid_t

  /// The connecting process's executable path (`lilpass`, or the app's own path if the app ever
  /// talks to itself), or `nil` if it couldn't be resolved (the process has already exited, or
  /// `proc_pidpath` failed for another reason).
  public var processPath: String?

  /// The name of `pid`'s parent process at connection time (e.g. `claude`, `codex`, `zsh`, or the
  /// app itself if it launched `lilpass` directly), or `nil` if it couldn't be resolved.
  public var parentProcessName: String?

  /// The connecting process's own code-signing identifier (`CFBundleIdentifier` for an app/tool
  /// built by this project, e.g. `com.851labs.lilpasswords`), or `nil` if it couldn't be resolved
  /// — unsigned/ad-hoc-signed processes (the default for local/CI builds) have no identifier to
  /// read. `AgentServer` uses this, not `processPath` (a spoofable string), to restrict
  /// `.unlock`/`.createVault` to the app specifically — see `AgentConnectionSecurity` for the
  /// same code-signing-based philosophy applied at the whole-connection level.
  public var bundleIdentifier: String?

  public init(
    pid: pid_t,
    processPath: String?,
    parentProcessName: String?,
    bundleIdentifier: String? = nil
  ) {
    self.pid = pid
    self.processPath = processPath
    self.parentProcessName = parentProcessName
    self.bundleIdentifier = bundleIdentifier
  }
}

/// Resolves a `CallerIdentity` from a pid using `libproc`/`sysctl`, both best-effort: any lookup
/// that fails just leaves the corresponding field `nil` rather than throwing, since a caller
/// identity that's harder to attribute is still more useful to the access log than none at all.
public enum CallerIdentityResolver {
  public static func resolve(pid: pid_t) -> CallerIdentity {
    CallerIdentity(
      pid: pid,
      processPath: processPath(of: pid),
      parentProcessName: parentProcessName(of: pid),
      bundleIdentifier: bundleIdentifier(attributes: [kSecGuestAttributePid as String: pid])
    )
  }

  /// Resolves an XPC peer from its connection's audit token rather than its bare pid. Preferred
  /// over ``resolve(pid:)`` for anything security-relevant: a pid can be reused by a completely
  /// different process between the moment `NSXPCListenerDelegate` accepts a connection and the
  /// moment this code asks the kernel "whose code signature is this?", which would let that new
  /// process inherit trust meant for whichever process actually held the connection. An audit
  /// token has no such reuse window — it identifies the exact process instance the kernel vended
  /// the connection for, not just a numeric slot that process happened to occupy.
  ///
  /// `pid` is threaded through unchanged for `processPath`/`parentProcessName` and the access
  /// log's display — those are diagnostic/cosmetic, not what any authorization decision reads.
  /// `AgentServer.isAppCaller(_:)` only ever reads `bundleIdentifier`, resolved here from the
  /// audit token, never from `pid` — so the pid-reuse race `processPath`/`parentProcessName`
  /// could theoretically still be subject to isn't security-relevant the way `bundleIdentifier`
  /// resolution is.
  public static func resolve(auditToken: audit_token_t, pid: pid_t) -> CallerIdentity {
    var token = auditToken
    let tokenData = withUnsafeBytes(of: &token) { Data($0) }
    return CallerIdentity(
      pid: pid,
      processPath: processPath(of: pid),
      parentProcessName: parentProcessName(of: pid),
      bundleIdentifier: bundleIdentifier(attributes: [kSecGuestAttributeAudit as String: tokenData])
    )
  }

  /// Resolves `connection`'s peer, preferring its audit token (``resolve(auditToken:pid:)``) and
  /// falling back to its bare pid only if the token can't be read at all — see ``auditToken(of:)``
  /// for when that's expected (never, on any macOS release this app has actually shipped or
  /// tested on) versus merely possible (a future OS quietly renaming the private storage it reads).
  public static func resolve(connection: NSXPCConnection) -> CallerIdentity {
    guard let token = auditToken(of: connection) else {
      FileHandle.standardError.write(
        Data(
          ("LilPasswordsAgent: couldn't read an XPC connection's audit token; falling back to its pid, "
            + "which is reusable and less trustworthy for caller identity\n").utf8
        )
      )
      return resolve(pid: connection.processIdentifier)
    }
    return resolve(auditToken: token, pid: connection.processIdentifier)
  }

  /// Reads `connection`'s underlying `audit_token_t` via the same private KVC key Apple's own
  /// `NSXPCConnection` stores it under (`"auditToken"`, an ivar of exactly `audit_token_t`'s size
  /// boxed in an `NSValue`) — there is no public API for this. `NSXPCConnection` publicly exposes
  /// `processIdentifier` (a bare, reusable pid) and `auditSessionIdentifier` (an *audit session*
  /// id shared by every process in one login session, not a per-connection audit token), but
  /// nothing that reaches an actual `audit_token_t`. This exact private-KVC technique is widely
  /// used by XPC-security-conscious code for precisely this "authenticate my XPC peer without a
  /// pid-reuse race" problem, in the absence of a public alternative.
  ///
  /// Verified directly against this codebase's own dev toolchain before relying on it here: a
  /// throwaway `NSXPCListener.anonymous()`/`NSXPCConnection` pair, probed on both the listener and
  /// client side after a real round-trip call, both returned an `NSValue` decoding to the
  /// process's own real pid at the expected `audit_token_t` offset — not `nil`, not garbage.
  ///
  /// Returns `nil` (rather than trapping) if the key is ever missing or its value isn't an
  /// `NSValue`, so a future SDK silently changing this falls back to pid-based resolution instead
  /// of crashing every XPC accept.
  private static func auditToken(of connection: NSXPCConnection) -> audit_token_t? {
    guard let value = connection.value(forKey: "auditToken") as? NSValue else { return nil }
    var token = audit_token_t()
    withUnsafeMutableBytes(of: &token) { buffer in
      value.getValue(buffer.baseAddress!)
    }
    return token
  }

  /// Shared by every `resolve` overload above: looks up the guest identified by `attributes`
  /// (either a `kSecGuestAttributePid` or `kSecGuestAttributeAudit` entry) and — critically —
  /// calls `SecCodeCheckValidity` on it before reading anything back. `SecCodeCopyGuestWithAttributes`
  /// succeeding only means "these attributes identify some running code guest"; it doesn't itself
  /// verify that guest's on-disk signature is still intact right now. Skipping
  /// `SecCodeCheckValidity` would mean trusting whatever `kSecCodeInfoIdentifier` a guest reports
  /// even if its signature had been invalidated since — validating first closes that gap. Ad-hoc
  /// signed builds (every local/CI build here — see `AgentConnectionSecurity`) still pass:
  /// `SecCodeCheckValidity` checks internal signature consistency, which an ad-hoc signature has,
  /// not the presence of a certificate chain.
  private static func bundleIdentifier(attributes: [String: Any]) -> String? {
    var codeRef: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, SecCSFlags(), &codeRef) == errSecSuccess,
      let code = codeRef
    else { return nil }

    guard SecCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess else { return nil }

    var infoRef: CFDictionary?
    // `SecCodeCopySigningInformation` takes a `SecStaticCode`; `SecCode` (a running guest, here)
    // is toll-free bridgeable to it, hence the forced cast rather than a public conversion API —
    // the same pattern `AgentConnectionSecurity.currentProcessTeamIdentifier()` uses.
    guard
      SecCodeCopySigningInformation(code as! SecStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        == errSecSuccess,
      let info = infoRef as? [String: Any]
    else { return nil }

    return info[kSecCodeInfoIdentifier as String] as? String
  }

  private static func processPath(of pid: pid_t) -> String? {
    // `PROC_PIDPATHINFO_MAXSIZE` is a `<libproc.h>` macro (`4 * MAXPATHLEN`), not imported into
    // Swift; `MAXPATHLEN` itself is available via Darwin, so compute it the same way libproc does.
    var buffer = [Int8](repeating: 0, count: Int(4 * MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return string(fromNulTerminated: buffer)
  }

  private static func parentPID(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
    guard result == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
  }

  private static func parentProcessName(of pid: pid_t) -> String? {
    guard let parentPID = parentPID(of: pid) else { return nil }
    var buffer = [Int8](repeating: 0, count: Int(MAXCOMLEN) * 4)
    let length = proc_name(parentPID, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return string(fromNulTerminated: buffer)
  }

  /// `proc_pidpath`/`proc_name` fill a fixed-size buffer and NUL-terminate; `String(cString:)` is
  /// deprecated in favor of decoding-then-truncating-at-NUL manually.
  private static func string(fromNulTerminated buffer: [Int8]) -> String? {
    let bytes = buffer.map { UInt8(bitPattern: $0) }
    let nulIndex = bytes.firstIndex(of: 0) ?? bytes.count
    return String(decoding: bytes[..<nulIndex], as: UTF8.self)
  }
}
