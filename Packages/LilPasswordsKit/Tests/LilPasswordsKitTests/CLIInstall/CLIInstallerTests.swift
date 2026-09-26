import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct CLIInstallerTests {
  /// A fresh, throwaway directory tree standing in for `/usr/local/bin`, `~/.local/bin`, and the
  /// app bundle's `Contents/Helpers/lilpass` — every test gets its own, so nothing here ever
  /// touches a real system or user directory.
  private struct Sandbox {
    let root: URL
    let embeddedBinary: String
    let installer: CLIInstaller

    init(systemBinWritable: Bool = true) throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
      let systemBin = root.appendingPathComponent("usr-local-bin", isDirectory: true)
      let userBin = root.appendingPathComponent("home/.local/bin", isDirectory: true)
      let appBundle = root.appendingPathComponent("lil passwords.app", isDirectory: true)
      let helpers = appBundle.appendingPathComponent("Contents/Helpers", isDirectory: true)
      try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
      let binary = helpers.appendingPathComponent("lilpass")
      try Data("#!/bin/sh\necho fake lilpass\n".utf8).write(to: binary)

      if systemBinWritable {
        try FileManager.default.createDirectory(at: systemBin, withIntermediateDirectories: true)
      } else {
        // A directory that exists but this process can't write into, simulating a `/usr/local/bin`
        // owned by another user/group.
        try FileManager.default.createDirectory(at: systemBin, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: systemBin.path)
      }

      embeddedBinary = binary.path
      installer = CLIInstaller(
        paths: CLIInstaller.Paths(
          embeddedBinary: binary.path,
          systemBinDirectory: systemBin.path,
          userBinDirectory: userBin.path
        )
      )
    }

    func cleanUp() {
      // Restore write permissions before recursive removal, or the read-only directory case
      // leaves files behind.
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: root.appendingPathComponent("usr-local-bin").path
      )
      try? FileManager.default.removeItem(at: root)
    }
  }

  @Test func notInstalledWhenNeitherLocationHasAnything() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    #expect(sandbox.installer.status() == .notInstalled)
  }

  @Test func installPrefersSystemBinWhenWritable() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }

    let location = try sandbox.installer.install()
    #expect(location == .systemBin)

    guard case .installed(let path) = sandbox.installer.status() else {
      Issue.record("expected .installed, got \(sandbox.installer.status())")
      return
    }
    #expect(path.hasSuffix("usr-local-bin/lilpass"))
  }

  @Test func installFallsBackToUserBinWhenSystemBinIsntWritable() throws {
    let sandbox = try Sandbox(systemBinWritable: false)
    defer { sandbox.cleanUp() }

    let location = try sandbox.installer.install()
    #expect(location == .userBin)

    guard case .installed(let path) = sandbox.installer.status() else {
      Issue.record("expected .installed, got \(sandbox.installer.status())")
      return
    }
    #expect(path.hasSuffix(".local/bin/lilpass"))
  }

  @Test func installIsIdempotent() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }

    try sandbox.installer.install()
    try sandbox.installer.install()
    let expectedPath = sandbox.root.appendingPathComponent("usr-local-bin/lilpass").path
    #expect(sandbox.installer.status() == .installed(path: expectedPath))
  }

  @Test func statusReportsPointsElsewhereForAStaleSymlink() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }

    // Simulate a symlink left behind from a different (or moved) app copy.
    let staleTarget = sandbox.root.appendingPathComponent("some-other-app/lilpass").path
    try FileManager.default.createDirectory(
      atPath: (staleTarget as NSString).deletingLastPathComponent,
      withIntermediateDirectories: true
    )
    try Data("stale".utf8).write(to: URL(fileURLWithPath: staleTarget))
    let linkPath = sandbox.root.appendingPathComponent("usr-local-bin/lilpass").path
    try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: staleTarget)

    #expect(sandbox.installer.status() == .pointsElsewhere(path: linkPath, target: staleTarget))
  }

  @Test func statusReportsPointsElsewhereForAnUnrelatedFile() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }

    let linkPath = sandbox.root.appendingPathComponent("usr-local-bin/lilpass").path
    try Data("#!/bin/sh\necho not us\n".utf8).write(to: URL(fileURLWithPath: linkPath))

    #expect(sandbox.installer.status() == .pointsElsewhere(path: linkPath, target: linkPath))
  }

  @Test func installReplacesAStaleSymlinkRatherThanFailing() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }

    let staleTarget = sandbox.root.appendingPathComponent("gone").path
    let linkPath = sandbox.root.appendingPathComponent("usr-local-bin/lilpass").path
    try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: staleTarget)

    try sandbox.installer.install()
    #expect(sandbox.installer.status() == .installed(path: linkPath))
  }

  @Test func uninstallRemovesTheSymlink() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }

    try sandbox.installer.install()
    try sandbox.installer.uninstall()
    #expect(sandbox.installer.status() == .notInstalled)
  }

  @Test func uninstallIsANoOpWhenNothingIsInstalled() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    try sandbox.installer.uninstall()
    #expect(sandbox.installer.status() == .notInstalled)
  }

  @Test func resolvedCommandPathIsTheEmbeddedBinaryWhenNotInstalled() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    #expect(sandbox.installer.resolvedCommandPath() == sandbox.embeddedBinary)
  }

  @Test func resolvedCommandPathIsTheSymlinkOnceInstalled() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    try sandbox.installer.install()
    let expectedPath = sandbox.root.appendingPathComponent("usr-local-bin/lilpass").path
    #expect(sandbox.installer.resolvedCommandPath() == expectedPath)
  }

  @Test func acceptableCommandPathsIncludesBothFormsWhenInstalled() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    try sandbox.installer.install()
    let expectedSymlinkPath = sandbox.root.appendingPathComponent("usr-local-bin/lilpass").path
    #expect(sandbox.installer.acceptableCommandPaths() == [expectedSymlinkPath, sandbox.embeddedBinary])
  }

  @Test func acceptableCommandPathsDedupesWhenNotInstalled() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    #expect(sandbox.installer.acceptableCommandPaths() == [sandbox.embeddedBinary])
  }
}
