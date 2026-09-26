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

  /// The connecting process's executable path (`lilpw`, or the app's own path if the app ever
  /// talks to itself), or `nil` if it couldn't be resolved (the process has already exited, or
  /// `proc_pidpath` failed for another reason).
  public var processPath: String?

  /// The name of `pid`'s parent process at connection time (e.g. `claude`, `codex`, `zsh`, or the
  /// app itself if it launched `lilpw` directly), or `nil` if it couldn't be resolved.
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
      bundleIdentifier: bundleIdentifier(of: pid)
    )
  }

  /// Reads the connecting process's own code-signing identifier via `SecCode`, the same
  /// `Security` framework machinery `AgentConnectionSecurity.currentProcessTeamIdentifier()` uses
  /// for its own process — best-effort, `nil` on any failure (unsigned/ad-hoc build, the process
  /// already exited, etc.) rather than throwing.
  private static func bundleIdentifier(of pid: pid_t) -> String? {
    var codeRef: SecCode?
    let attributes = [kSecGuestAttributePid as String: pid] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &codeRef) == errSecSuccess,
      let code = codeRef
    else { return nil }

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
