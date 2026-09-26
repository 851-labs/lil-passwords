import Foundation
import LilPasswordsKit

/// Bridges the 851-2428 agent-access settings into an `ObservableObject` `AgentsSettingsView` can
/// bind to directly with `$`, the same shape `ObservableAppSettings` gives the rest of Settings —
/// except these two toggles are no longer backed by `AppSettings`/`UserDefaults` at all. They're
/// owned by `LilPasswordsAgent` itself, in a helper-owned `AgentSettingsStoring` Keychain item (see
/// that protocol's documentation), and this view model reads/writes them exclusively through
/// `AgentClient.agentSettings()`/`.setAgentSettings(_:)` — never `AppSettings`.
///
/// **Security history (851-2428 review):** these toggles used to live in `AppSettings`'s shared,
/// any-process-writable `UserDefaults` suite, which meant any local process could silently flip
/// "Allow agents to access passwords" back on with a bare `defaults write`. Routing every read and
/// write through the helper's gated `getAgentSettings`/`setAgentSettings` XPC ops (restricted to the
/// app's own, code-signing-verified connection — see `AgentServer.isAppCaller(_:)`) closes that gap:
/// changing the setting now requires being the app, not just knowing a domain name.
@MainActor
final class AgentSettingsViewModel: ObservableObject {
  @Published var agentAccessEnabled: Bool = false {
    didSet {
      guard !isApplyingRemoteUpdate, oldValue != agentAccessEnabled else { return }
      push()
    }
  }

  @Published var keepAgentAccessAvailableWhileMacUnlocked: Bool = false {
    didSet {
      guard !isApplyingRemoteUpdate, oldValue != keepAgentAccessAvailableWhileMacUnlocked else { return }
      push()
    }
  }

  private let client: AgentClient

  /// Set while applying a value read *from* the helper, so that write-back-on-`didSet` doesn't
  /// immediately turn right around and re-send the very value it just received.
  private var isApplyingRemoteUpdate = false

  init(client: AgentClient) {
    self.client = client
  }

  /// Reads the current settings from the helper. Call from `.task` when the pane appears — the
  /// helper is the sole source of truth, so there's no meaningful "initial" value to show before
  /// this completes; both toggles simply start `false` (matching the helper's own fail-closed
  /// default) until it does.
  func refresh() async {
    let settings = (try? await client.agentSettings()) ?? .disabled
    apply(settings)
  }

  /// Pushes the current toggle values to the helper. On failure (e.g. the connection dropped, or
  /// this process somehow isn't the verified app caller), re-reads the helper's actual settings so
  /// the UI reflects reality rather than an optimistic value that was silently rejected.
  private func push() {
    let settings = AgentSettings(
      agentAccessEnabled: agentAccessEnabled,
      keepAgentAccessAvailableWhileMacUnlocked: keepAgentAccessAvailableWhileMacUnlocked
    )
    Task {
      do {
        let updated = try await client.setAgentSettings(settings)
        apply(updated)
      } catch {
        await refresh()
      }
    }
  }

  private func apply(_ settings: AgentSettings) {
    isApplyingRemoteUpdate = true
    agentAccessEnabled = settings.agentAccessEnabled
    keepAgentAccessAvailableWhileMacUnlocked = settings.keepAgentAccessAvailableWhileMacUnlocked
    isApplyingRemoteUpdate = false
  }
}
