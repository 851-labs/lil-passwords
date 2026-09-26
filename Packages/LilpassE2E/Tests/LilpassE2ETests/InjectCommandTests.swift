import Foundation
import LilPasswordsKit
import LilpassCore
import Testing

/// `lilpass inject -i <template> -o <output>`: replaces every `{{ lilpass://item/field }}` placeholder
/// with its resolved secret. Exercised here against real template/output files on disk (in a
/// throwaway temp directory — never anywhere near a real project checkout) and the real binary,
/// including the atomicity guarantee `LilpassInject.inject` documents: a template that fails to
/// resolve must leave `-o`'s file untouched.
///
/// `.timeLimit(.minutes(1))`: every test here talks to a real subprocess over real XPC, and
/// this suite has twice hung a CI job for its full 30-minute timeout with zero output when one
/// of those calls never returned — a per-test time limit turns that into a fast, attributable
/// failure (naming exactly which test timed out) instead of another silent freeze.
///
/// `.serialized`: see `MCPStdioSessionTests`'s doc comment and `CommandsTests`'s for the full
/// rationale — a Swift runtime generic-metadata-cache livelock triggered by parallel first-time
/// instantiation of the same generic type, now suspected to be racing across this package's suites
/// rather than only within `MCPStdioSessionTests`.
@Suite(.timeLimit(.minutes(1)), .serialized)
struct InjectCommandTests {
  init() {
    HangWatchdog.arm()
    HangWatchdog.trace("InjectCommandTests.init()")
  }

  @Test func substitutesEveryPlaceholderAndWritesTheOutputFile() throws {
    let item = makeE2ETestItem(title: "GitHub", usernames: ["octocat"], password: "hunter2")
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath, items: [item])
    defer { helper.stop() }

    let directory = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let templateURL = directory.appendingPathComponent("template.env")
    let outputURL = directory.appendingPathComponent("output.env")
    try """
    GITHUB_USER={{ lilpass://GitHub/username }}
    GITHUB_TOKEN={{ lilpass://GitHub/password }}
    """.write(to: templateURL, atomically: true, encoding: .utf8)

    let result = try LilpassBinary.run(
      ["inject", "-i", templateURL.path, "-o", outputURL.path],
      extraEnvironment: env(for: helper)
    )
    #expect(result.exitCode == LilpassExitCode.ok.rawValue)
    #expect(result.stdout.contains("wrote"))

    let written = try String(contentsOf: outputURL, encoding: .utf8)
    #expect(written.contains("GITHUB_USER=octocat"))
    #expect(written.contains("GITHUB_TOKEN=hunter2"))
    #expect(!written.contains("lilpass://"))
  }

  @Test func aTemplateWithAnUnresolvableReferenceWritesNothing() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath)
    defer { helper.stop() }

    let directory = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let templateURL = directory.appendingPathComponent("template.env")
    let outputURL = directory.appendingPathComponent("output.env")
    try """
    FIRST={{ lilpass://nonexistent-item/password }}
    """.write(to: templateURL, atomically: true, encoding: .utf8)

    let result = try LilpassBinary.run(
      ["inject", "-i", templateURL.path, "-o", outputURL.path],
      extraEnvironment: env(for: helper)
    )
    #expect(result.exitCode == LilpassExitCode.notFound.rawValue)
    #expect(!FileManager.default.fileExists(atPath: outputURL.path))
  }

  @Test func aMissingInputFileFailsWithUsage() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpassBinary.helperPath)
    defer { helper.stop() }

    let directory = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let result = try LilpassBinary.run(
      [
        "inject", "-i", directory.appendingPathComponent("does-not-exist.env").path, "-o",
        directory.appendingPathComponent("out.env").path,
      ],
      extraEnvironment: env(for: helper)
    )
    #expect(result.exitCode == LilpassExitCode.usage.rawValue)
  }

  private func makeScratchDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lilpass-e2e-inject-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func env(for helper: E2EHelperProcess) -> [String: String] {
    ["LILPASS_E2E_MACH_SERVICE_NAME": helper.machServiceName]
  }
}
