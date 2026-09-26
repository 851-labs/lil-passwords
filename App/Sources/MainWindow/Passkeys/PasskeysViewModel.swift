import Combine
import Foundation
import LilPasswordsKit

/// Publishes the Passkeys category's list, backed directly by ``AgentClient`` rather than
/// ``VaultViewModel`` — passkeys (851-2442) aren't `PasswordItem`s, and `VaultViewModel`'s
/// in-memory `dataSource` doesn't know about them at all (see `MainWindowController`'s doc
/// comments on `dataSource` remaining a `PasswordItem`-only placeholder). This mirrors
/// `WiFiNetworkViewModel`'s shape — an `ObservableObject` owning the category's one `@Published`
/// list plus the actions its list/detail views need — but reads through the real helper XPC
/// connection instead of shelling out to a system tool.
///
/// A passkey's private key never appears here: ``AgentClient/passkeys()`` already returns the
/// secret-free ``PasskeyMetadata`` shape (relying party, user name/display name, website,
/// created/last-used dates — no key material, no sign count), matching the ticket's "agents get
/// no access to passkey private keys" requirement for every reader of the vault, this view model
/// included.
@MainActor
final class PasskeysViewModel: ObservableObject {
  @Published private(set) var passkeys: [PasskeyMetadata] = []

  /// True whenever the most recent refresh failed because the vault is locked — the Passkeys list
  /// shows its own "locked" empty state rather than an empty-but-unlocked one when this is set,
  /// the same distinction `ItemListViewController`'s ancestor makes via `dataSource.items` simply
  /// being empty until unlock.
  @Published private(set) var isLocked: Bool = false

  private let agentClient: AgentClient

  /// Refreshes on the same cross-process signal `CredentialIdentityStoreSyncCoordinator` already
  /// observes: an AutoFill-extension-driven `passkeyRegister`/`passkeyAssert` (or an app-side
  /// delete) posts this after committing, so the list picks up a passkey created or used from the
  /// system's AutoFill picker without the app process polling for it.
  private var vaultChangeObserver: DarwinNotificationObserver?

  init(agentClient: AgentClient) {
    self.agentClient = agentClient
  }

  /// Starts observing cross-process vault changes — called once, after `viewDidLoad`, mirroring
  /// `CredentialIdentityStoreSyncCoordinator.start()`. Separate from `init` so a test can construct
  /// this view model without also wiring up a live `CFNotificationCenter` observer.
  func startObservingVaultChanges() {
    guard vaultChangeObserver == nil else { return }
    vaultChangeObserver = DarwinNotificationObserver(name: DarwinNotifications.vaultChanged) { [weak self] in
      guard let self else { return }
      Task { await self.refresh() }
    }
  }

  /// Re-fetches the passkey list. Safe to call repeatedly (e.g. every time the Passkeys sidebar
  /// category is selected, or in response to `vaultChangeObserver` firing).
  func refresh() async {
    #if DEBUG
      // Shown immediately, *before* the real `await` below, rather than only on a `.locked`
      // failure or once the real fetch resolves — unlike `WiFiNetworkViewModel.refresh()`'s
      // quick, local, always-completes `knownNetworks()` scan, `agentClient.passkeys()` is a real
      // XPC round trip that can hang indefinitely rather than fail fast when no helper is
      // reachable at all (e.g. this app launched in an environment with no registered launchd
      // helper — confirmed via `lilpass status` itself hanging past a 120s timeout there). Gating
      // the sample data on that call completing made `-PasskeysDebugSampleData YES` useless for
      // exactly the tophat/manual-QA captures it exists for. Setting it here first means the
      // Passkeys list always has content the instant this is called, and the block below still
      // merges in (or falls back to) real data whenever that call does resolve.
      if Self.isDebugSampleDataEnabled {
        passkeys = SampleData.makePasskeys(now: Date())
        isLocked = false
      }
    #endif
    do {
      var fetched = try await agentClient.passkeys()
      #if DEBUG
        if Self.isDebugSampleDataEnabled {
          fetched = SampleData.makePasskeys(now: Date()) + fetched
        }
      #endif
      passkeys = fetched.sorted { lhs, rhs in
        Self.title(for: lhs).localizedStandardCompare(Self.title(for: rhs)) == .orderedAscending
      }
      isLocked = false
    } catch AgentClient.RequestError.remote(.locked) {
      #if DEBUG
        if Self.isDebugSampleDataEnabled {
          passkeys = SampleData.makePasskeys(now: Date())
          isLocked = false
          return
        }
      #endif
      passkeys = []
      isLocked = true
    } catch {
      // Any other transport/remote error leaves the previous list on screen rather than clearing
      // it out from under the person looking at it — matches `WiFiNetworkViewModel.refresh()`'s
      // "best effort" treatment of a failed scan. In DEBUG with the sample-data flag on, "the
      // previous list" is exactly the sample data just set above.
    }
  }

  /// Permanently deletes the passkey at `id` — the Passkeys detail card's Delete button — then
  /// re-fetches so the list and any other selection reflect the removal immediately, without
  /// waiting on `vaultChangeObserver` (this process's own write doesn't need the cross-process
  /// round trip to know about itself).
  func delete(id: UUID) async throws {
    try await agentClient.deletePasskey(id: id)
    await refresh()
  }

  /// The list/detail title for a passkey: its website's host when known, falling back to the raw
  /// relying party identifier (e.g. a passkey registered before a website URL was ever resolved).
  static func title(for passkey: PasskeyMetadata) -> String {
    passkey.website?.host ?? passkey.relyingPartyIdentifier
  }

  #if DEBUG
    /// `-PasskeysDebugSampleData YES` prepends `SampleData.makePasskeys(now:)`'s synthetic
    /// passkeys to whatever the real vault reports (or shows them alone while locked) — mirroring
    /// `WiFiNetworkViewModel`'s `-WiFiDebugFakeNetwork` convention, so a tophat/manual-QA capture
    /// of the Passkeys list and detail card can be scripted without a real AutoFill registration
    /// (which needs the provisioning profile — see 851-2441's notes) or an unlocked real vault.
    /// Never compiled into Release builds.
    private static var isDebugSampleDataEnabled: Bool {
      UserDefaults.standard.bool(forKey: "PasskeysDebugSampleData")
    }
  #endif
}
