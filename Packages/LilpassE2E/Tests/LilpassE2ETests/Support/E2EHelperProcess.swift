import Foundation
import LilPasswordsKit

/// Manages one disposable `LilpassE2EHelper` process for exactly one test, registered with launchd
/// under a unique, per-test Mach service name via `launchctl bootstrap`/`bootout` — the same
/// on-demand Mach-service activation mechanism the real `LilPasswordsAgent` uses in production
/// (see docs/adr/0001-storage-and-process-model.md and
/// `Agent/Support/com.851labs.lilpasswords.agent.plist`), just pointed at a throwaway plist in a
/// temp directory instead of an installed app bundle's `LaunchAgents`.
///
/// `gui/<uid>` (not `user/<uid>`) is required: it's the domain a real, GUI-logged-in user's
/// LaunchAgents use, and it's confirmed active even on a CI runner (an unattended `macos-15`
/// GitHub Actions runner still has an Aqua login session — `launchctl print gui/<uid>` there shows
/// `session = Aqua`). `runLaunchctl` below captures stderr and bounds every `launchctl` call with a
/// 10-second timeout instead of running under `try?`/discarding output, so a genuine `launchctl`
/// failure surfaces as a fast, explicit `LaunchctlFailure` rather than an unexplained hang — this
/// suite once hung CI for a full 30-minute job timeout with zero output, though the actual cause
/// turned out to be unrelated to launchd entirely (see `MCPStdioSessionTests`'s doc comment).
///
/// Every name this generates (the LaunchAgent label, the Mach service name, the temp work
/// directory) includes a fresh UUID, and nothing here ever calls `launchctl setenv` (which is
/// session-wide) — both are required per this ticket's "use temp dirs and unique service names;
/// several agents build this app concurrently on this Mac" constraint. Combined with
/// `LilpassE2EHelper`'s exclusive use of `InMemoryVaultStore`, nothing this type or the process it
/// launches does can ever touch `~/Library/Application Support/Lil Passwords` or the real
/// Keychain item, or collide with another concurrent test/agent run on the same Mac.
final class E2EHelperProcess {
  /// Where `AgentEndpoint.makeClient()` (via `LILPASS_E2E_MACH_SERVICE_NAME`) should point a
  /// `lilpass`/`lilpass mcp` subprocess to reach this specific helper instance.
  let machServiceName: String

  /// Per-instance scratch space: the generated plist, and the helper's own stdout/stderr
  /// (redirected here rather than inherited, since launchd detaches the process from this test's
  /// own stdio). Removed by ``stop()``.
  let workDirectory: URL

  private let label: String
  private var isBootstrapped = false

  private static let uid = getuid()

  private init(machServiceName: String, label: String, workDirectory: URL) {
    self.machServiceName = machServiceName
    self.label = label
    self.workDirectory = workDirectory
  }

  /// Writes a throwaway LaunchAgent plist for `LilpassE2EHelper` into a fresh temp directory and
  /// `launchctl bootstrap`s it, so the very next `NSXPCConnection(machServiceName:)` naming this
  /// instance's ``machServiceName`` activates a freshly seeded helper on demand.
  ///
  /// - Parameters:
  ///   - helperBinaryPath: Absolute path to the built `LilpassE2EHelper` executable. `make e2e`
  ///     builds this explicitly (see the Makefile) and passes it down via
  ///     `LILPASS_E2E_HELPER_BINARY_PATH`, which every test reads via ``LilpassBinary``.
  ///   - items: Fixture items to seed into the helper's `InMemoryVaultStore` before it serves any
  ///     connection.
  ///   - locked: If `true`, the helper locks the vault immediately after seeding.
  ///   - accessDisabled: If `true`, the helper uses `AlwaysDenyAccessPolicy` instead of
  ///     `AlwaysAllowAccessPolicy`.
  static func start(
    helperBinaryPath: String,
    items: [PasswordItem] = [],
    locked: Bool = false,
    accessDisabled: Bool = false
  ) throws -> E2EHelperProcess {
    let id = UUID().uuidString.lowercased()
    // Used as both the LaunchAgent `Label` and the `MachServices` key/`AgentClient` target name —
    // one unique string is simpler than two, and nothing validates any relationship between them
    // (unlike production's real bundle-identifier-based code-signing check, which this test
    // double deliberately opts out of via `.developmentFallback`; see `LilpassE2EHelper/main.swift`).
    let name = "com.851labs.lilpasswords.e2e.\(id)"
    let workDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("lilpass-e2e-\(id)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

    var environmentVariables: [String: String] = [
      "LILPASS_E2E_MACH_SERVICE_NAME": name
    ]
    if !items.isEmpty {
      let data = try AgentWireCoding.encoder.encode(items)
      environmentVariables["LILPASS_E2E_FIXTURE_ITEMS_B64"] = data.base64EncodedString()
    }
    if locked {
      environmentVariables["LILPASS_E2E_LOCKED"] = "1"
    }
    if accessDisabled {
      environmentVariables["LILPASS_E2E_ACCESS_DISABLED"] = "1"
    }

    let plist: [String: Any] = [
      "Label": name,
      "Program": helperBinaryPath,
      "MachServices": [name: true],
      "EnvironmentVariables": environmentVariables,
      "StandardOutPath": workDirectory.appendingPathComponent("helper.stdout.log").path,
      "StandardErrorPath": workDirectory.appendingPathComponent("helper.stderr.log").path,
      "ProcessType": "Interactive",
    ]
    let plistURL = workDirectory.appendingPathComponent("helper.plist")
    let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try plistData.write(to: plistURL)

    try runLaunchctl(["bootstrap", "gui/\(uid)", plistURL.path], failureContext: "bootstrap \(name)")

    let helper = E2EHelperProcess(machServiceName: name, label: name, workDirectory: workDirectory)
    helper.isBootstrapped = true
    return helper
  }

  /// Tears down the helper: `launchctl bootout` (harmless even if the helper never actually
  /// activated — an on-demand Mach service with no pending connection may never have launched at
  /// all) and removes the temp work directory. Every test must call this, even on failure — the
  /// usual pattern is `defer { helper.stop() }` right after `start(...)` succeeds.
  func stop() {
    guard isBootstrapped else { return }
    isBootstrapped = false
    _ = try? Self.runLaunchctl(["bootout", "gui/\(Self.uid)/\(label)"], failureContext: "bootout \(label)")
    try? FileManager.default.removeItem(at: workDirectory)
  }

  deinit {
    // A safety net, not the primary teardown path (`stop()` also removes the temp directory,
    // which a bare `bootout` here can't do) — every test should still call `stop()` explicitly.
    if isBootstrapped {
      _ = try? Self.runLaunchctl(["bootout", "gui/\(Self.uid)/\(label)"], failureContext: "bootout \(label)")
    }
  }

  struct LaunchctlFailure: Error, CustomStringConvertible {
    let description: String
  }

  /// Runs `launchctl` with a bounded wall-clock timeout, capturing stderr so a failure explains
  /// itself instead of surfacing as a silent, indefinite hang downstream. `launchctl` itself is
  /// normally near-instant either way; 10 seconds is generous headroom, not a tuned budget.
  @discardableResult
  private static func runLaunchctl(_ arguments: [String], failureContext: String) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    let stderrPipe = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = stderrPipe
    try process.run()

    let deadline = DispatchTime.now() + .seconds(10)
    while process.isRunning, DispatchTime.now() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
      throw LaunchctlFailure(
        description: "launchctl \(arguments.joined(separator: " ")) (\(failureContext)) timed out after 10s")
    }

    let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? nil
    process.waitUntilExit()
    let exitCode = process.terminationStatus
    if exitCode != 0 {
      let stderrText = stderrData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      throw LaunchctlFailure(
        description:
          "launchctl \(arguments.joined(separator: " ")) (\(failureContext)) exited \(exitCode): \(stderrText)")
    }
    return exitCode
  }
}
