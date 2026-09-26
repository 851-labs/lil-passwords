import Foundation

/// A non-zero exit from a shelled-out command, carrying enough to distinguish known cases (like
/// `security find-generic-password`'s exit code 44 for "not found") from a generic failure.
public struct WiFiSystemCommandFailure: Error, Sendable, Equatable {
  public let exitCode: Int32
  public let standardError: String

  public init(exitCode: Int32, standardError: String) {
    self.exitCode = exitCode
    self.standardError = standardError
  }
}

/// A thin seam over `Process`, so ``SystemWiFiNetworkListing`` and ``SystemWiFiPasswordRevealing``
/// can be exercised in tests without actually shelling out. Mirrors the `Process`/`Pipe` pattern
/// already used by `SystemClaudeCodeCLI` elsewhere in this package.
public protocol WiFiSystemCommandRunning: Sendable {
  /// Runs `executable` with `arguments` to completion and returns its standard output, decoded as
  /// UTF-8 (empty string if it produced none, or the bytes aren't valid UTF-8).
  ///
  /// Throws ``WiFiSystemCommandFailure`` for any non-zero exit status.
  func run(executable: String, arguments: [String]) throws -> String
}

/// The real conformer, backed by `Foundation.Process`.
public struct RealWiFiSystemCommandRunner: WiFiSystemCommandRunning {
  public init() {}

  public func run(executable: String, arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      let message = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      throw WiFiSystemCommandFailure(exitCode: process.terminationStatus, standardError: message)
    }
    return String(data: stdoutData, encoding: .utf8) ?? ""
  }
}
