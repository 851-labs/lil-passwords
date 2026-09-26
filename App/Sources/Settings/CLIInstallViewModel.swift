import Foundation
import LilPasswordsKit

/// Bridges `CLIInstaller` (`LilPasswordsKit`) into an `ObservableObject` for Settings → Agents →
/// "Command Line Tool" (851-2432).
///
/// Kept deliberately thin: all the actual symlink logic (and the reasoning for why it falls back
/// to `~/.local/bin` instead of an admin-privileges prompt) lives in `CLIInstaller` itself, where
/// it has real unit test coverage against temp directories. This view model just owns the
/// `@Published` status SwiftUI observes and translates install/uninstall into a refresh.
@MainActor
final class CLIInstallViewModel: ObservableObject {
  @Published private(set) var status: CLIInstallStatus = .notInstalled
  @Published private(set) var lastErrorMessage: String?

  private let installer: CLIInstaller

  init(installer: CLIInstaller = CLIInstaller(paths: CLIInstallViewModel.defaultInstallerPaths())) {
    self.installer = installer
  }

  /// `CLIInstaller.defaultPaths()`, unless `LIL_PASSWORDS_DEBUG_CLI_INSTALL_ROOT` is set (DEBUG
  /// builds only), in which case the system/user bin directories are redirected under that root
  /// instead of the real `/usr/local/bin`/`~/.local/bin` — mirrors `Pasteboard`'s
  /// `LIL_PASSWORDS_DEBUG_CLIPBOARD_CLEAR_INTERVAL` escape hatch. Exists so tophat screenshots of
  /// the "installed"/"not installed" states can be captured deterministically on a shared dev
  /// machine without writing a real symlink into either real location. Never read outside DEBUG
  /// builds, and the embedded binary path is untouched either way — only where the symlink is
  /// looked for/created changes.
  static func defaultInstallerPaths() -> CLIInstaller.Paths {
    var paths = CLIInstaller.defaultPaths()
    #if DEBUG
      if let root = ProcessInfo.processInfo.environment["LIL_PASSWORDS_DEBUG_CLI_INSTALL_ROOT"] {
        paths.systemBinDirectory = root + "/usr-local-bin"
        paths.userBinDirectory = root + "/local-bin"
      }
    #endif
    return paths
  }

  func refresh() {
    status = installer.status()
  }

  func install() {
    do {
      _ = try installer.install()
      lastErrorMessage = nil
    } catch {
      lastErrorMessage = "Couldn't install the \(LilPasswordsKit.cliName) command: \(error.localizedDescription)"
    }
    refresh()
  }

  func uninstall() {
    do {
      try installer.uninstall()
      lastErrorMessage = nil
    } catch {
      lastErrorMessage = "Couldn't remove the \(LilPasswordsKit.cliName) command: \(error.localizedDescription)"
    }
    refresh()
  }
}
