import Foundation
import LilPasswordsKit
import LilpwCore
import Testing

/// `lilpw inject -i <template> -o <output>`: replaces every `{{ lilpw://item/field }}` placeholder
/// with its resolved secret. Exercised here against real template/output files on disk (in a
/// throwaway temp directory — never anywhere near a real project checkout) and the real binary,
/// including the atomicity guarantee `LilpwInject.inject` documents: a template that fails to
/// resolve must leave `-o`'s file untouched.
@Suite struct InjectCommandTests {
  @Test func substitutesEveryPlaceholderAndWritesTheOutputFile() throws {
    let item = makeE2ETestItem(title: "GitHub", usernames: ["octocat"], password: "hunter2")
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath, items: [item])
    defer { helper.stop() }

    let directory = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let templateURL = directory.appendingPathComponent("template.env")
    let outputURL = directory.appendingPathComponent("output.env")
    try """
    GITHUB_USER={{ lilpw://GitHub/username }}
    GITHUB_TOKEN={{ lilpw://GitHub/password }}
    """.write(to: templateURL, atomically: true, encoding: .utf8)

    let result = try LilpwBinary.run(
      ["inject", "-i", templateURL.path, "-o", outputURL.path],
      extraEnvironment: env(for: helper)
    )
    #expect(result.exitCode == LilpwExitCode.ok.rawValue)
    #expect(result.stdout.contains("wrote"))

    let written = try String(contentsOf: outputURL, encoding: .utf8)
    #expect(written.contains("GITHUB_USER=octocat"))
    #expect(written.contains("GITHUB_TOKEN=hunter2"))
    #expect(!written.contains("lilpw://"))
  }

  @Test func aTemplateWithAnUnresolvableReferenceWritesNothing() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath)
    defer { helper.stop() }

    let directory = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let templateURL = directory.appendingPathComponent("template.env")
    let outputURL = directory.appendingPathComponent("output.env")
    try """
    FIRST={{ lilpw://nonexistent-item/password }}
    """.write(to: templateURL, atomically: true, encoding: .utf8)

    let result = try LilpwBinary.run(
      ["inject", "-i", templateURL.path, "-o", outputURL.path],
      extraEnvironment: env(for: helper)
    )
    #expect(result.exitCode == LilpwExitCode.notFound.rawValue)
    #expect(!FileManager.default.fileExists(atPath: outputURL.path))
  }

  @Test func aMissingInputFileFailsWithUsage() throws {
    let helper = try E2EHelperProcess.start(helperBinaryPath: LilpwBinary.helperPath)
    defer { helper.stop() }

    let directory = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let result = try LilpwBinary.run(
      [
        "inject", "-i", directory.appendingPathComponent("does-not-exist.env").path, "-o",
        directory.appendingPathComponent("out.env").path,
      ],
      extraEnvironment: env(for: helper)
    )
    #expect(result.exitCode == LilpwExitCode.usage.rawValue)
  }

  private func makeScratchDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lilpw-e2e-inject-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func env(for helper: E2EHelperProcess) -> [String: String] {
    ["LILPW_E2E_MACH_SERVICE_NAME": helper.machServiceName]
  }
}
