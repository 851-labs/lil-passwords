import Foundation

/// Where a `lilpass` symlink was found (or would be created), for 851-2432's Settings →
/// Agents → "Command Line Tool" section.
public enum CLIInstallLocation: String, Sendable, Equatable, CaseIterable {
  /// `/usr/local/bin` (or whatever ``CLIInstaller/Paths/systemBinDirectory`` points at) — already
  /// on every standard shell's `PATH`, so this is preferred whenever it's writable without
  /// elevated privileges.
  case systemBin
  /// `~/.local/bin` (or whatever ``CLIInstaller/Paths/userBinDirectory`` points at) — the fallback
  /// when the system location isn't writable. Increasingly common as a user-scoped install
  /// location (pipx, cargo, rustup, and others all default here or somewhere equivalent), but not
  /// guaranteed to be on `PATH` out of the box, so the UI should say so.
  case userBin
}

/// The state of the `lilpass` command-line symlink, as reported by ``CLIInstaller/status()``.
public enum CLIInstallStatus: Sendable, Equatable {
  /// No `lilpass` symlink (or file) at either candidate location.
  case notInstalled
  /// A symlink at `path` resolves to this running app's own embedded `lilpass` binary — installed,
  /// and current.
  case installed(path: String)
  /// Something already occupies the candidate path, but it isn't a symlink into this app's own
  /// bundle — either a symlink into a *different* copy of the app (e.g. one installed elsewhere,
  /// or a stale copy from before the app moved), or an unrelated file entirely. `target` is the
  /// symlink's destination, or `path` again if it isn't a symlink at all.
  case pointsElsewhere(path: String, target: String)
}

/// Installs, checks, and removes the `lilpass` symlink described in 851-2432: a symlink from a
/// `PATH` directory to the `lilpass` binary embedded in this app's own bundle
/// (`Contents/Helpers/lilpass` — see `project.yml`), so a terminal (or an agent shelling out) can
/// just run `lilpass` once it's installed.
///
/// **Why a plain writability check + fallback, not an admin-privileges prompt:** `/usr/local/bin`
/// is writable without elevation on most Mac setups (anywhere Homebrew or Xcode's command line
/// tools have already claimed it for the current user/admin group), so trying it directly first
/// covers the common case with zero prompts. When it isn't writable, this falls back to
/// `~/.local/bin` instead of escalating — no `AuthorizationServices` prompt, no
/// `osascript … with administrator privileges` shell-out. Both of those need a password prompt
/// (which trains users to click through Touch ID/admin dialogs for a CLI tool install — exactly
/// the kind of prompt fatigue that makes a *real* privilege-escalation attempt less noticeable
/// later) and, for the `osascript` route specifically, hand-assembled shell text is an injection
/// surface that's simply better to not have at all. `~/.local/bin` needs no privilege escalation,
/// is a directory this process can always create and write to, and is where a growing number of
/// other CLI installers (pipx, cargo, rustup, and others) already put user-scoped binaries — the
/// only cost is that a fresh shell profile may not have it on `PATH` yet, which the UI surfaces
/// rather than silently working around.
///
/// Every path is injected via ``Paths`` rather than hardcoded, so tests can point this at temp
/// directories instead of touching a real `/usr/local/bin` or `~/.local/bin`.
///
/// `@unchecked Sendable`, matching `AppSettings`' own reasoning: `FileManager`'s instance methods
/// (the only thing this type calls on it) are documented as safe to use from multiple threads —
/// see its header doc — but the class predates Swift concurrency's `Sendable` audits, so the
/// compiler can't verify that itself.
public struct CLIInstaller: @unchecked Sendable {
  /// The filesystem locations this installer reads and writes. All injectable for testability;
  /// ``defaultPaths(bundle:)`` supplies the real ones a production build should use.
  public struct Paths: Sendable, Equatable {
    /// The `lilpass` binary embedded in this app's own bundle — the symlink's destination.
    /// Built from the *running app's* bundle path (not a build-directory path), so the symlink
    /// keeps working across in-place app updates that replace bundle contents without moving the
    /// bundle itself.
    public var embeddedBinary: String
    /// Preferred install directory — `/usr/local/bin` in production.
    public var systemBinDirectory: String
    /// Fallback install directory — `~/.local/bin` in production.
    public var userBinDirectory: String

    public init(embeddedBinary: String, systemBinDirectory: String, userBinDirectory: String) {
      self.embeddedBinary = embeddedBinary
      self.systemBinDirectory = systemBinDirectory
      self.userBinDirectory = userBinDirectory
    }
  }

  private let paths: Paths
  private let fileManager: FileManager

  public init(paths: Paths, fileManager: FileManager = .default) {
    self.paths = paths
    self.fileManager = fileManager
  }

  /// The real paths a production build should use: `lilpass` inside `bundle`'s own
  /// `Contents/Helpers`, `/usr/local/bin`, and `~/.local/bin`.
  public static func defaultPaths(bundle: Bundle = .main) -> Paths {
    Paths(
      embeddedBinary: bundle.bundlePath + "/Contents/Helpers/" + LilPasswordsKit.cliName,
      systemBinDirectory: "/usr/local/bin",
      userBinDirectory: NSHomeDirectory() + "/.local/bin"
    )
  }

  /// The name of the symlink to create — always `lilpass` (``LilPasswordsKit/cliName``).
  public var linkName: String { LilPasswordsKit.cliName }

  private var systemLinkPath: String {
    (paths.systemBinDirectory as NSString).appendingPathComponent(linkName)
  }

  private var userLinkPath: String {
    (paths.userBinDirectory as NSString).appendingPathComponent(linkName)
  }

  /// Checks the system location first, then the user location, matching install's own preference
  /// order.
  public func status() -> CLIInstallStatus {
    if let status = describe(at: systemLinkPath) { return status }
    if let status = describe(at: userLinkPath) { return status }
    return .notInstalled
  }

  private func describe(at path: String) -> CLIInstallStatus? {
    if let destination = try? fileManager.destinationOfSymbolicLink(atPath: path) {
      let resolved = resolvedDestination(destination, relativeTo: path)
      return resolved == paths.embeddedBinary
        ? .installed(path: path)
        : .pointsElsewhere(path: path, target: resolved)
    }
    if fileManager.fileExists(atPath: path) {
      // Something's there, but it isn't a symlink at all — an unrelated program owns this name.
      return .pointsElsewhere(path: path, target: path)
    }
    return nil
  }

  private func resolvedDestination(_ destination: String, relativeTo linkPath: String) -> String {
    guard !(destination as NSString).isAbsolutePath else { return destination }
    let directory = (linkPath as NSString).deletingLastPathComponent
    return ((directory as NSString).appendingPathComponent(destination) as NSString).standardizingPath
  }

  /// Creates (or replaces) the `lilpass` symlink, preferring ``CLIInstallLocation/systemBin`` and
  /// falling back to ``CLIInstallLocation/userBin`` — see this type's documentation for why the
  /// fallback is silent rather than an admin-privileges prompt. Replaces whatever was already at
  /// the chosen path (including a stale symlink from a previous app location), so re-running this
  /// after an app update or move re-points the link rather than failing.
  @discardableResult
  public func install() throws -> CLIInstallLocation {
    if (try? installLink(inDirectory: paths.systemBinDirectory)) != nil {
      return .systemBin
    }
    try installLink(inDirectory: paths.userBinDirectory)
    return .userBin
  }

  private func installLink(inDirectory directory: String) throws {
    try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let path = (directory as NSString).appendingPathComponent(linkName)
    if fileManager.fileExists(atPath: path) || (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil {
      try fileManager.removeItem(atPath: path)
    }
    try fileManager.createSymbolicLink(atPath: path, withDestinationPath: paths.embeddedBinary)
  }

  /// Removes whichever candidate symlink(s) ``status()`` currently finds — safe even if what's
  /// there is a stale link into a different app copy (``CLIInstallStatus/pointsElsewhere``), since
  /// this only ever touches the well-known `lilpass` name in these two specific directories, never
  /// an arbitrary path. A no-op (not an error) when nothing is installed.
  public func uninstall() throws {
    for path in [systemLinkPath, userLinkPath] {
      guard fileManager.fileExists(atPath: path) || (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
      else { continue }
      try fileManager.removeItem(atPath: path)
    }
  }
}
