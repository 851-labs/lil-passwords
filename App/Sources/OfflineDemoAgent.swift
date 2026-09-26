#if DEBUG
  import Foundation
  import LilPasswordsKit

  /// A `VaultAgentConnecting` that never touches XPC, the legacy Keychain, or the on-disk vault
  /// database — everything lives in a handful of `@MainActor` properties on this one object.
  ///
  /// **Why this exists:** this Mac runs several concurrent worktrees of this same app side by
  /// side, and `AgentXPC.machServiceName` plus `VaultStore.defaultDatabaseURL()` are both fixed,
  /// unparameterized constants — every one of those worktrees' locally-built apps and helpers
  /// resolves to the *same* Mach service name and the *same* on-disk vault, regardless of which
  /// checkout built them. That's fine for the real, shipped app (there's only ever one), but it
  /// means a locally-run debug build can't safely exercise "first run" / "locked" / "unlock
  /// failed" for a screenshot without either racing another session's manual testing or leaving
  /// the shared vault in a state some other worktree's test run didn't expect.
  ///
  /// `LILPASSWORDS_OFFLINE_DEMO=1` (checked in `MainWindowController`, alongside the existing
  /// `LILPASSWORDS_FAKE_AUTH` escape hatch) swaps this in for the real `AgentClient` instead, so
  /// 851-2422's lock screen — and 851-2411's unlock/lock transitions — can be driven and
  /// screenshotted deterministically with no shared machine state involved at all. Never wired
  /// into a Release build; see `MainWindowController.makeAgent(real:)`.
  final class OfflineDemoAgent: VaultAgentConnecting, @unchecked Sendable {
    private let mutex = NSLock()
    private var vaultExists = true
    private var locked = true

    func status() async throws -> AgentStatus {
      mutex.withLock { AgentStatus(locked: locked, agentAccessEnabled: true, vaultExists: vaultExists) }
    }

    func createVault() async throws -> String {
      mutex.withLock {
        vaultExists = true
        locked = false
      }
      return "4S9K-D2XQ-7RTN-8YCB-J3WM"
    }

    func unlock() async throws {
      mutex.withLock { locked = false }
    }

    func lock() async throws {
      mutex.withLock { locked = true }
    }
  }
#endif
