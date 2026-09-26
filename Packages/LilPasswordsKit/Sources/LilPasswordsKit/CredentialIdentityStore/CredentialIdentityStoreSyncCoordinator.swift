import Foundation

/// Drives ``CredentialIdentityStoreSyncing`` off the real vault, for 851-2441's AutoFill extension.
///
/// Deliberately talks to the real vault through ``AgentClient``/XPC — the same helper connection
/// the rest of the app uses — rather than through the app's own `VaultViewModel`
/// (`MainWindowController.init`'s `InMemoryVaultStore`-backed placeholder, pending the item
/// list's own move to the real, XPC-backed store): `ASCredentialIdentityStore` entries are only
/// useful if their `recordIdentifier` is a real vault item id the AutoFill extension's own
/// `.autoFillCredential(id:)` XPC request can actually resolve later. Syncing from a throwaway,
/// in-memory, per-launch list would populate the system's store with ids that don't exist in the
/// real vault at all.
///
/// **Two triggers, from two different signals, matching the plan's "after every mutation, and
/// after the initial post-unlock load":**
/// - ``start()`` observes the vault's own cross-process change notification
///   (`DarwinNotifications.vaultChanged`, ADR 0001(d)) — posted by `VaultStore` after every
///   successful create/update/delete/restore/purge, from *any* process (this app, `lilpass`, a
///   future client), so every mutation eventually reaches here regardless of which process made
///   it.
/// - Unlocking doesn't itself rewrite the vault database, so it never posts that notification —
///   `MainWindowController.presentUnlockedContent()` calls ``refresh()`` directly instead, right
///   after the app's own `LockCoordinator` reports `.unlocked`.
///
/// ``refresh()`` is the one method that matters for testing: it's a plain, direct
/// `AgentClient.list()` call handed to a ``CredentialIdentityStoreSyncing``, easily exercised
/// end-to-end over a real (in-process, anonymous-listener) XPC connection with a fake syncer. By
/// contrast, ``start()`` is a thin, deliberately untested wrapper around it — the same treatment
/// this package already gives `LockStateObserver`/the module-internal `DarwinNotificationObserver`
/// it wires up here, both themselves thin `CFNotificationCenter` callback trampolines with no
/// tests of their own.
@MainActor
public final class CredentialIdentityStoreSyncCoordinator {
  private let agentClient: AgentClient
  private let syncer: any CredentialIdentityStoreSyncing
  private var vaultChangeObserver: DarwinNotificationObserver?

  public init(agentClient: AgentClient, syncer: any CredentialIdentityStoreSyncing = ASCredentialIdentityStoreSync()) {
    self.agentClient = agentClient
    self.syncer = syncer
  }

  /// Starts observing the vault's change notification for as long as this coordinator is alive.
  /// Safe to call more than once — a second call simply replaces the first observer with an
  /// identical one — but callers only ever need to call it once, at app launch.
  public func start() {
    vaultChangeObserver = DarwinNotificationObserver(name: DarwinNotifications.vaultChanged) { [weak self] in
      guard let self else { return }
      Task { await self.refresh() }
    }
  }

  /// Fetches the vault's current items over XPC and hands them to ``CredentialIdentityStoreSyncing``.
  /// Silently does nothing on any failure — locked, helper unreachable, anything else
  /// `AgentClient.list()` can throw — rather than surfacing an error: there's no UI for this
  /// coordinator to report to, and the next vault change or unlock will simply try again with a
  /// fresh snapshot.
  public func refresh() async {
    guard let items = try? await agentClient.list() else { return }
    await syncer.sync(items: items)
  }
}
