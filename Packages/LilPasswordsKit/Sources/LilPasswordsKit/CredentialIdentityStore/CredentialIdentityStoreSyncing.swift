import Foundation

/// 851-2441: keeps macOS's system credential identity store (`ASCredentialIdentityStore`) in sync
/// with the vault's current items — service identifiers and usernames only, **never** a password
/// — so Safari/system AutoFill can offer "lil passwords" as a source without launching this app or
/// its extension first.
///
/// A seam, matching this file's neighbors' own philosophy (`VaultStoring`/`AccessPolicyProviding`):
/// the real conformer, ``ASCredentialIdentityStoreSync``, talks to a real system API that's
/// impractical to exercise meaningfully in a unit test (it depends on whether *this* build's
/// AutoFill extension is actually registered and enabled in System Settings — see that type's own
/// documentation on the provisioning-profile blocker), so tests that care about the pure "which
/// items map to an identity, and which don't" logic call ``ASCredentialIdentityStoreSync``'s own
/// mapping helper directly, while tests that care about *when* a sync happens (``CredentialIdentityStoreSyncCoordinator``)
/// use a fake conformer instead.
public protocol CredentialIdentityStoreSyncing: Sendable {
  /// Replaces whatever this conformer previously stored with exactly one entry per eligible item
  /// in `items` (see ``ASCredentialIdentityStoreSync``'s eligibility rules) — not an incremental
  /// diff. Never throws: a conformer that can fail (the real one can, if the system call itself
  /// fails) should swallow that itself, since there's no UI surface calling code can usefully show
  /// a sync failure on; the next call (the vault's own next change, or the next post-unlock
  /// refresh) simply tries again with a fresh, complete snapshot.
  func sync(items: [PasswordItem]) async
}
