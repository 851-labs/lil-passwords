import AuthenticationServices
import Foundation

/// The real ``CredentialIdentityStoreSyncing`` conformer: replaces `ASCredentialIdentityStore`'s
/// entire contents with one `ASPasswordCredentialIdentity` per eligible ``PasswordItem`` on every
/// ``sync(items:)`` call.
///
/// **Eligibility** (see ``identities(for:)``): an item needs a non-empty username *and* a website
/// with a resolvable host to produce an identity at all — an item with neither, or only one, simply
/// isn't offered by system AutoFill (there'd be nothing useful to search it by, or nothing to fill
/// once chosen). Soft-deleted items (`deletedAt != nil`) are always excluded, matching every other
/// "live items" filter in this package (e.g. `AgentServer.isLive(_:)`). `recordIdentifier` is the
/// item's own `id.uuidString` — this is what `CredentialProviderViewController` reads back out of
/// `ASPasswordCredentialIdentity.recordIdentifier` and round-trips through
/// `AgentClient.autoFillCredential(id:)`, so it must always be exactly the vault's real item id,
/// nothing derived or re-encoded.
///
/// **Clear-on-lock: deliberately not done.** Nothing in this type or its caller
/// (``CredentialIdentityStoreSyncCoordinator``) ever calls this while the vault is locked with an
/// intent to empty the store — the coordinator simply skips a refresh it can't complete (see its
/// own documentation). The store's entries are non-secret service+username pairs only, no more
/// sensitive than what this app's own item list UI already shows, and macOS is specifically
/// designed to invoke the AutoFill extension *while the Mac is locked or the vault hasn't been
/// unlocked yet* (`provideCredentialWithoutUserInteraction(for:)`/
/// `prepareInterfaceToProvideCredential(for:)`), routing to the extension's own lock-gated
/// `.autoFillCredential(id:)` request for the actual password. Clearing the store on every lock
/// would silently stop offering "lil passwords" as an AutoFill source across every auto-lock, for
/// no corresponding security benefit — the thing that's actually gated behind unlocking is the
/// password, not whether the system knows this app *has* a "netflix.com" entry at all.
///
/// **Provisioning-profile blocker:** `ASCredentialIdentityStore.shared.getState(completion:)`
/// reports `isEnabled == false` — making ``sync(items:)`` a no-op — for any process whose
/// containing app doesn't have a real, System-Settings-enabled AutoFill extension, which (per
/// docs/adr/0005-autofill-credential-provider.md) isn't possible with only ad-hoc/personal-team
/// signing. This type still builds and can be unit-tested via ``identities(for:)`` (a pure
/// function, independent of the real system store's state) even before that's resolved.
public struct ASCredentialIdentityStoreSync: CredentialIdentityStoreSyncing {
  public init() {}

  public func sync(items: [PasswordItem], passkeys: [PasskeyIdentity]) async {
    let store = ASCredentialIdentityStore.shared
    guard await Self.isEnabled(of: store) else { return }

    await Self.removeAll(from: store)

    // Passkeys (851-2442) need the macOS 14+ `saveCredentialIdentities(_:)` overload that accepts
    // a mixed `[any ASCredentialIdentity]` array (`ASPasswordCredentialIdentity` and
    // `ASPasskeyCredentialIdentity` both conform) — on macOS 13, there's no such thing as a passkey
    // identity to register at all, so this falls back to the original password-only overload.
    if #available(macOS 14, *) {
      let entries: [any ASCredentialIdentity] = Self.identities(for: items) + Self.passkeyIdentities(for: passkeys)
      guard !entries.isEmpty else { return }
      await Self.save(entries, to: store)
    } else {
      let identities = Self.identities(for: items)
      guard !identities.isEmpty else { return }
      await Self.save(identities, to: store)
    }
  }

  /// The pure item → identity mapping, exposed separately from ``sync(items:passkeys:)`` so tests
  /// can verify it directly without depending on `ASCredentialIdentityStore.shared`'s real,
  /// environment-dependent enabled state (see this type's own documentation).
  static func identities(for items: [PasswordItem]) -> [ASPasswordCredentialIdentity] {
    items
      .filter { $0.deletedAt == nil }
      .compactMap { item -> ASPasswordCredentialIdentity? in
        guard let username = item.usernames.first(where: { !$0.isEmpty }), !username.isEmpty else { return nil }
        guard let host = item.websites.first?.host, !host.isEmpty else { return nil }
        return ASPasswordCredentialIdentity(
          serviceIdentifier: ASCredentialServiceIdentifier(identifier: host, type: .domain),
          user: username,
          recordIdentifier: item.id.uuidString
        )
      }
  }

  /// The 851-2442 passkey analog of ``identities(for:)``: every ``PasskeyIdentity`` with a
  /// non-empty relying party id becomes one `ASPasskeyCredentialIdentity`, carrying its
  /// `credentialId`/`userHandle` (neither secret — see `PasskeyIdentity`'s own documentation) but
  /// never a private key, which this type has no field to carry in the first place.
  /// `PasskeyIdentity.id` (the vault item id) is the `recordIdentifier`, the same role
  /// ``identities(for:)`` gives `PasswordItem.id` — round-tripped back out by
  /// `CredentialProviderViewController` the same way.
  @available(macOS 14, *)
  static func passkeyIdentities(for passkeys: [PasskeyIdentity]) -> [ASPasskeyCredentialIdentity] {
    passkeys.compactMap { passkey -> ASPasskeyCredentialIdentity? in
      guard !passkey.relyingPartyIdentifier.isEmpty else { return nil }
      return ASPasskeyCredentialIdentity(
        relyingPartyIdentifier: passkey.relyingPartyIdentifier,
        userName: passkey.userName,
        credentialID: passkey.credentialId,
        userHandle: passkey.userHandle,
        recordIdentifier: passkey.id.uuidString
      )
    }
  }

  /// Extracts just `isEnabled` (a trivially `Sendable` `Bool`) inside the completion closure,
  /// rather than resuming the continuation with the whole `ASCredentialIdentityStoreState` —
  /// the latter isn't provably `Sendable`, which Swift 6's strict concurrency checking flags as a
  /// "sending risks data races" error when it crosses the continuation's isolation boundary.
  private static func isEnabled(of store: ASCredentialIdentityStore) async -> Bool {
    await withCheckedContinuation { continuation in
      store.getState { state in continuation.resume(returning: state.isEnabled) }
    }
  }

  private static func removeAll(from store: ASCredentialIdentityStore) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      store.removeAllCredentialIdentities { _, _ in continuation.resume() }
    }
  }

  private static func save(_ identities: [ASPasswordCredentialIdentity], to store: ASCredentialIdentityStore) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      store.saveCredentialIdentities(identities) { _, _ in continuation.resume() }
    }
  }

  /// The macOS 14+ mixed-entry overload (`saveCredentialIdentityEntries:completion:`, Swift name
  /// `saveCredentialIdentities(_:completion:)` — distinguished from the overload above purely by
  /// its `[any ASCredentialIdentity]` parameter type) used once ``sync(items:passkeys:)`` has any
  /// `ASPasskeyCredentialIdentity` entries to register alongside the password ones.
  @available(macOS 14, *)
  private static func save(_ entries: [any ASCredentialIdentity], to store: ASCredentialIdentityStore) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      store.saveCredentialIdentities(entries) { _, _ in continuation.resume() }
    }
  }
}
