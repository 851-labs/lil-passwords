import Darwin
import Foundation

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

  public init(pid: pid_t, processPath: String?, parentProcessName: String?) {
    self.pid = pid
    self.processPath = processPath
    self.parentProcessName = parentProcessName
  }
}

/// Resolves a `CallerIdentity` from a pid using `libproc`/`sysctl`, both best-effort: any lookup
/// that fails just leaves the corresponding field `nil` rather than throwing, since a caller
/// identity that's harder to attribute is still more useful to the access log than none at all.
public enum CallerIdentityResolver {
  public static func resolve(pid: pid_t) -> CallerIdentity {
    CallerIdentity(pid: pid, processPath: processPath(of: pid), parentProcessName: parentProcessName(of: pid))
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
