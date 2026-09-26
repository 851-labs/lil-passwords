import Foundation

/// Diagnostic instrumentation for the CI-only hang tracked in `.github/workflows/ci.yml`'s E2E
/// step comment and `MCPStdioSessionTests`'s doc comment: this package has now hung a CI job for
/// its *entire* 10-minute step timeout with **zero test output at all** — worse than the earlier,
/// already-"fixed" incident (a `swift::MetadataCacheEntryBase::awaitSatisfyingState` generic-
/// metadata-cache livelock inside `Client.connect(transport:)`, fixed by serializing
/// `MCPStdioSessionTests`). Zero output means the hang is now either before any test body runs at
/// all, or in a suite that isn't `MCPStdioSessionTests`.
///
/// This type gives every future hang two independent ways to leave a trace in the log instead of
/// silently eating the step timeout:
///
/// 1. `trace(_:)` — an unconditional, unbuffered write straight to fd 2 (not `print`, not
///    anything that could itself be stuck behind a buffered/line-buffered stdout that a livelocked
///    process never flushes) from every suite `init()` and every harness entry/exit point. If a
///    future hang happens before some suite's first test even starts, the last `trace` line CI
///    printed says exactly which suite got that far.
/// 2. `arm()` — installs a detached watchdog thread (idempotently; safe to call from every suite's
///    `init()`) that, 90 seconds after the *first* suite constructs, dumps every thread's
///    backtrace by running `sample` against this process's own pid and then hard-exits with
///    `exit(1)` — so a livelock that produces no test output and would otherwise just run out the
///    clock instead fails fast with a stack dump identifying the actual spin site.
enum HangWatchdog {
  private static let armed: Void = {
    trace("HangWatchdog.arm(): first suite constructed, arming 90s watchdog")
    let thread = Thread {
      Thread.sleep(forTimeInterval: 90)
      trace("HangWatchdog: no test completed within 90s of the first suite constructing — sampling self and exiting")
      dumpBacktraces()
      trace("HangWatchdog: sample complete, exiting with status 1")
      exit(1)
    }
    thread.name = "HangWatchdog"
    thread.stackSize = 1 << 20
    thread.start()
  }()

  /// Idempotent: only the first call from any suite actually starts the watchdog thread; every
  /// later call (from every other suite's `init()`) is a cheap no-op via `static let`'s
  /// once-only initialization.
  static func arm() {
    _ = armed
  }

  /// An unconditional, unbuffered stderr write — deliberately not `print`/`FileHandle.standardError
  /// .write` via a `String` that could round-trip through a buffered stream, so this shows up in
  /// CI's log immediately, even moments before a livelock, rather than sitting in a buffer no one
  /// ever flushes.
  static func trace(_ message: String, file: String = #fileID, line: Int = #line) {
    let line = "[HangWatchdog \(timestamp()) \(file):\(line)] \(message)\n"
    line.utf8CString.withUnsafeBufferPointer { buffer in
      // -1 to not count the trailing NUL `utf8CString` adds.
      _ = write(2, buffer.baseAddress, buffer.count - 1)
    }
  }

  /// Runs `/usr/bin/sample` against this process's own pid so CI's log ends up with the same
  /// per-thread call-graph a human would get running `sample <pid>` by hand against a stuck local
  /// repro — `-mayDie` because we're intentionally sampling a process that's about to `exit(1)`.
  private static func dumpBacktraces() {
    let pid = ProcessInfo.processInfo.processIdentifier
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    process.arguments = [String(pid), "5", "-mayDie"]
    process.standardOutput = FileHandle.standardError
    process.standardError = FileHandle.standardError
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      trace("HangWatchdog: failed to launch `sample \(pid)`: \(error)")
    }
  }

  private static func timestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
  }
}
