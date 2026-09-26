import Foundation

/// Diagnostics for chasing 851-2434's CI-only hang: two CI runs froze for a full 30-minute job
/// timeout with *zero* test output, and a third (after adding per-test `.timeLimit` traits and a
/// `LilpassBinary.run()` subprocess watchdog) still produced zero output for the entire 10-minute
/// step timeout that replaced it, right after `swift test`'s own build step finished — meaning
/// whatever hangs does so before any of this suite's existing timeouts (all of which start their
/// clock *after* `Process.run()` returns) ever get a chance to fire.
///
/// An earlier version of this file wrapped every `Process.run()` call in a background-thread +
/// `DispatchSemaphore` timeout to test that theory directly — that wrapper turned out to be
/// broken in its own right: running it locally made *every* `launchctl bootstrap` call across the
/// whole suite immediately fail with "process.run() did not return within 10.0s", even though the
/// exact same calls, made synchronously, complete near-instantly (as they did before that change,
/// and as they still do with it reverted). That's a self-inflicted regression from routing
/// `Process.run()` through GCD's global concurrent queue under this suite's normal test
/// parallelism, not evidence about the real CI hang — reverted in favor of the plain, synchronous
/// `try process.run()` this suite always used, with logging (see `log` below) added immediately
/// before and after each call instead, so the next CI run can at least show whether `run()` itself
/// is the thing that never returns, without changing how or where it's actually called.
///
/// `print()`/`Swift.print` output was separately confirmed to stream incrementally even through a
/// non-tty pipe locally (`make e2e | cat` showed partial output well before the run finished), so
/// C stdio buffering differences between a TTY and CI's piped, non-interactive stdout were ruled
/// out as a reason CI might show nothing even if the suite were making progress — but `log` below
/// uses `FileHandle.standardOutput.write` (a direct `write(2)`, bypassing C stdio's buffering
/// entirely) anyway, purely to remove even the possibility of buffering swallowing the one piece
/// of evidence a hang would leave behind.
enum E2EDiagnostics {
  static func log(_ message: String) {
    let line = "[e2e-diag] \(Date().description) \(message)\n"
    FileHandle.standardOutput.write(Data(line.utf8))
  }
}
