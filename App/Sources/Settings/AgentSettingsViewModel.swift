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

  /// Settings → Agents → "Allow agents to create, edit, and delete passwords" (851-2433) — a
  /// separate, narrower toggle than `agentAccessEnabled`; see `AgentSettings.agentWriteAccessEnabled`'s
  /// documentation for why it's meaningless on its own without read access also being on.
  /// `AgentsSettingsView` disables this toggle's control whenever `agentAccessEnabled` is off, to
  /// reflect that dependency visually, but the helper enforces it regardless of what the UI shows.
  @Published var agentWriteAccessEnabled: Bool = false {
    didSet {
      guard !isApplyingRemoteUpdate, oldValue != agentWriteAccessEnabled else { return }
      push()
    }
  }

  /// Settings → Agents → the "All passwords" / "Only selected passwords" / "Ask every time" picker
  /// (851-2445) — see `AgentAccessScope`'s documentation and `docs/adr/0007-scoped-agent-access.md`
  /// for the three modes' semantics. Mutually exclusive, not stackable with the toggles above.
  @Published var accessScope: AgentAccessScope = .allPasswords {
    didSet {
      guard !isApplyingRemoteUpdate, oldValue != accessScope else { return }
      push()
    }
  }

  /// The `.selected` allowlist's item ids. Populated per-item from `ItemListViewController`'s
  /// context menu (each screen constructs its own short-lived `AgentClient` for that, per the ADR),
  /// not edited directly in this view model — kept here only so `push()` round-trips it instead of
  /// clobbering it back to empty every time an unrelated toggle flips.
  @Published private(set) var allowedItemIDs: Set<UUID> = []

  /// The `.selected` allowlist's group names. Unlike `allowedItemIDs`, there's no natural per-item
  /// surface for adding a *group* (a group isn't a single row with a context menu of its own), so
  /// `AgentsSettingsView` manages this list directly by name.
  @Published var allowedGroups: Set<String> = [] {
    didSet {
      guard !isApplyingRemoteUpdate, oldValue != allowedGroups else { return }
      push()
    }
  }

  private let client: AgentClient

  /// Set while applying a value read *from* the helper, so that write-back-on-`didSet` doesn't
  /// immediately turn right around and re-send the very value it just received.
  private var isApplyingRemoteUpdate = false

  /// - Parameter initialSettings: Applied synchronously before this initializer returns, so the very
  ///   first SwiftUI render already reflects it — bypassing the usual `.task { await refresh() }`
  ///   round trip entirely. Production call sites never pass this (the helper is the sole source of
  ///   truth, per `refresh()`'s doc comment); it exists solely for `AgentTophatDebugMenu`, whose
  ///   capture runs inside a manually-pumped, deeply-nested `RunLoop.current.run(until:)` chain where
  ///   a real async XPC round trip through `client.agentSettings()` was empirically observed to take
  ///   several seconds to resume — and no fixed wait proved reliably long enough to capture it. Baking
  ///   the scenario's settings in synchronously sidesteps that race rather than out-waiting it.
  init(client: AgentClient, initialSettings: AgentSettings? = nil) {
    self.client = client
    if let initialSettings {
      apply(initialSettings)
    }
  }

  /// Reads the current settings from the helper. Call from `.task` when the pane appears — the
  /// helper is the sole source of truth, so there's no meaningful "initial" value to show before
  /// this completes; both toggles simply start `false` (matching the helper's own fail-closed
  /// default) until it does.
  func refresh() async {
    let settings = (try? await client.agentSettings()) ?? .disabled
    apply(settings)
  }

  /// Removes every individually-allowed item from the `.selected` allowlist (the group allowlist is
  /// untouched — see `allowedGroups`). Exposed as an explicit action, rather than a `Published`
  /// setter, because item ids are otherwise only ever added one at a time from the item list's
  /// context menu, never edited in bulk from this pane.
  func clearAllowedItems() {
    guard !allowedItemIDs.isEmpty else { return }
    allowedItemIDs = []
    push()
  }

  /// Pushes the current settings to the helper. On failure (e.g. the connection dropped, or this
  /// process somehow isn't the verified app caller), re-reads the helper's actual settings so the UI
  /// reflects reality rather than an optimistic value that was silently rejected.
  ///
  /// Includes every field of `AgentSettings`, not just the toggles this view model itself exposes
  /// setters for — reconstructing from only a subset here previously reset `accessScope`/
  /// `allowedItemIDs`/`allowedGroups` back to their memberwise-init defaults on every push (851-2445
  /// fix): `AgentSettings`'s initializer defaults those three fields, so omitting them here didn't
  /// "leave them alone," it silently zeroed them out.
  private func push() {
    let settings = AgentSettings(
      agentAccessEnabled: agentAccessEnabled,
      keepAgentAccessAvailableWhileMacUnlocked: keepAgentAccessAvailableWhileMacUnlocked,
      agentWriteAccessEnabled: agentWriteAccessEnabled,
      accessScope: accessScope,
      allowedItemIDs: allowedItemIDs,
      allowedGroups: allowedGroups
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
    agentWriteAccessEnabled = settings.agentWriteAccessEnabled
    accessScope = settings.accessScope
    allowedItemIDs = settings.allowedItemIDs
    allowedGroups = settings.allowedGroups
    isApplyingRemoteUpdate = false
  }
}
