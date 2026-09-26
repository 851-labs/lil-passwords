import Foundation

/// Where to find the two binaries this suite runs as real subprocesses, and a convenience for
/// running `lilpw` and capturing its stdout/stderr/exit code.
///
/// Both paths come from environment variables the Makefile's `e2e` target sets explicitly (see
/// `make e2e`), rather than anything computed at runtime here (e.g. from `Bundle.main` or
/// `CommandLine.arguments[0]`, which don't reliably identify "where did `swift test` put its
/// build products" the same way across an XCTest-hosted run and a standalone swift-testing
/// runner): the Makefile already knows exactly where `xcodebuild` and `swift build` put each
/// binary, so it's the simplest, most robust place to hand that down.
enum LilpwBinary {
  /// Absolute path to the *built* `lilpw` binary — `xcodebuild`'s output, not anything this
  /// package compiles — e.g. `build/Build/Products/Debug/Lil Passwords.app/Contents/Helpers/lilpw`.
  /// Set by `make e2e` via `LILPW_E2E_BINARY_PATH` after `make build`.
  static var lilpwPath: String {
    guard let path = ProcessInfo.processInfo.environment["LILPW_E2E_BINARY_PATH"], !path.isEmpty else {
      fatalError(
        """
        LILPW_E2E_BINARY_PATH is not set. Run this suite via `make e2e` (which builds the app \
        first and points this at build/Build/Products/Debug/.../Contents/Helpers/lilpw), not \
        directly via `swift test --package-path Packages/LilpwE2E`.
        """
      )
    }
    return path
  }

  /// Absolute path to the built `LilpwE2EHelper` executable. Set by `make e2e` via
  /// `LILPW_E2E_HELPER_BINARY_PATH`, computed from `swift build --show-bin-path` after building
  /// it explicitly — `LilpwE2EHelper` isn't a dependency of `LilpwE2ETests` (it only ever runs as
  /// a subprocess, never linked in), so plain `swift test` wouldn't build it on its own.
  static var helperPath: String {
    guard let path = ProcessInfo.processInfo.environment["LILPW_E2E_HELPER_BINARY_PATH"], !path.isEmpty else {
      fatalError(
        "LILPW_E2E_HELPER_BINARY_PATH is not set. Run this suite via `make e2e`, not directly via `swift test`."
      )
    }
    return path
  }

  struct Result {
    let stdout: String
    let stderr: String
    let exitCode: Int32
  }

  /// Runs the built `lilpw` binary with `arguments`, waits for it to exit, and captures its
  /// output. `extraEnvironment` is overlaid on this test process's own environment — every
  /// caller is expected to at least set `LILPW_E2E_MACH_SERVICE_NAME` (see
  /// `E2EHelperProcess.machServiceName`) so the subprocess talks to a disposable test helper
  /// instead of trying (and failing, or worse, succeeding against a real one) to reach the real
  /// `LilPasswordsAgent`.
  static func run(
    _ arguments: [String],
    extraEnvironment: [String: String] = [:],
    workingDirectory: URL? = nil
  ) throws -> Result {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: lilpwPath)
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    for (key, value) in extraEnvironment {
      environment[key] = value
    }
    process.environment = environment
    if let workingDirectory {
      process.currentDirectoryURL = workingDirectory
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()

    // Drain both pipes concurrently with waiting for exit: a child that writes enough output to
    // fill a pipe's kernel buffer before anyone reads it would otherwise deadlock against
    // `waitUntilExit()`. None of this suite's commands produce that much output, but reading
    // eagerly costs nothing and removes the failure mode entirely.
    let stdoutData = try stdoutPipe.fileHandleForReading.readToEndCompat()
    let stderrData = try stderrPipe.fileHandleForReading.readToEndCompat()

    process.waitUntilExit()

    return Result(
      stdout: String(data: stdoutData, encoding: .utf8) ?? "",
      stderr: String(data: stderrData, encoding: .utf8) ?? "",
      exitCode: process.terminationStatus
    )
  }

  /// Starts `lilpw mcp` as a long-lived subprocess with pipe-backed stdio, for
  /// `MCPStdioSessionTests` to drive a real MCP `Client` session against. The caller owns the
  /// returned `Process` (terminate it when done — `lilpw mcp` runs until its stdin closes or it's
  /// killed, it never exits on its own).
  static func startMCPServer(extraEnvironment: [String: String]) throws -> (
    process: Process, stdin: Pipe, stdout: Pipe
  ) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: lilpwPath)
    process.arguments = ["mcp"]
    var environment = ProcessInfo.processInfo.environment
    for (key, value) in extraEnvironment {
      environment[key] = value
    }
    process.environment = environment

    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    // Route the child's stderr to this test process's own, rather than a third unread pipe —
    // `lilpw mcp` doesn't write protocol data there, only diagnostics, and an unread stderr pipe
    // risks the same fill-the-buffer deadlock `run(_:)` avoids above.
    process.standardError = FileHandle.standardError

    try process.run()
    return (process, stdin, stdout)
  }
}

extension FileHandle {
  /// `readToEnd()` (the throwing, `Data?`-returning method Foundation added alongside
  /// `readDataToEndOfFile()`) under a name that doesn't collide with it, just normalized to a
  /// non-optional `Data` — an empty read is indistinguishable from "no output" for every caller
  /// here.
  fileprivate func readToEndCompat() throws -> Data {
    try readToEnd() ?? Data()
  }
}
