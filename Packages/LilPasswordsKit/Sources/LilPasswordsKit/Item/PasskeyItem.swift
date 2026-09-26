import Foundation

/// A single WebAuthn passkey the vault holds on the user's behalf (851-2442).
///
/// `PasskeyItem` is the plaintext shape a caller works with — the same role `PasswordItem` plays
/// for logins. It never appears on disk or in `VaultStore` on its own: `PasskeyRecordCodec` seals
/// it into a `VaultRecord` before it's persisted, so every field here — including
/// ``privateKeyPKCS8`` — ends up inside ciphertext rather than in a plaintext database column.
/// See `docs/adr/0002-crypto.md`.
///
/// ``privateKeyPKCS8`` in particular must never be sent anywhere outside `LilPasswordsAgent`: it
/// is the P-256 signing key a relying party trusts to authenticate this user, and it is decrypted
/// only inside the helper's in-memory `VaultStoreCore` index. `AgentServer`'s wire types
/// (`PasskeyMetadata`) are a deliberately narrow view that never includes it — see
/// `AgentProtocol.swift`.
public struct PasskeyItem: Codable, Sendable, Hashable {
  /// A stable, globally unique identifier for this vault entry, generated once when the passkey
  /// is created and never reused. Distinct from ``credentialId``, which is the WebAuthn
  /// credential id the relying party actually knows about.
  public var id: UUID

  /// The relying party identifier (e.g. `"webauthn.io"`) this passkey is scoped to — WebAuthn's
  /// `rpId`. Used both for display (it's the closest thing a passkey has to `PasswordItem.title`)
  /// and to compute `authenticatorData`'s `rpIdHash`.
  public var relyingPartyIdentifier: String

  /// The opaque user handle the relying party assigned at registration (WebAuthn's `user.id`).
  /// Returned verbatim in every assertion so the relying party can look the account back up;
  /// never reused across relying parties.
  public var userHandle: Data

  /// The account name the relying party asked for at registration (WebAuthn's `user.name`) —
  /// typically an email or username.
  public var userName: String

  /// The human-readable name the relying party asked for at registration (WebAuthn's
  /// `user.displayName`). Falls back to ``userName`` for display when empty.
  public var userDisplayName: String

  /// The WebAuthn credential id this passkey registered under. Returned to the relying party in
  /// both registration and assertion responses, and is how `LilPasswordsAgent` looks a passkey
  /// back up for `passkeyAssert`.
  public var credentialId: Data

  /// The P-256 private key, DER-encoded as PKCS8, that signs every assertion for this passkey.
  ///
  /// This is the one field in the entire vault this ticket's trust model singles out: it is
  /// sealed exactly like the rest of `PasskeyItem`'s plaintext (no separate key hierarchy — see
  /// `docs/adr/0002-crypto.md`), but every call site that reads a decrypted `PasskeyItem` back
  /// out of `VaultStoreCore` must keep it inside `LilPasswordsAgent`. Signing happens via
  /// `AgentServer`'s `passkeyAssert`/`passkeyRegister` handlers, which use this field and return
  /// only the signature/attestation bytes — never this key itself — to the caller.
  public var privateKeyPKCS8: Data

  /// WebAuthn's signature counter: incremented by one on every successful assertion (never on
  /// registration, where it starts at 0). Relying parties use it to detect cloned authenticators;
  /// see `docs/adr/0005-autofill-credential-provider.md` for how `passkeyAssert` increments it.
  public var signCount: UInt32

  /// When this passkey was created (registered).
  public var createdAt: Date

  /// When this passkey last signed an assertion, or `nil` if it's never been used since creation.
  public var lastUsedAt: Date?

  public init(
    id: UUID = .v7(),
    relyingPartyIdentifier: String,
    userHandle: Data,
    userName: String,
    userDisplayName: String,
    credentialId: Data,
    privateKeyPKCS8: Data,
    signCount: UInt32 = 0,
    createdAt: Date = Date(),
    lastUsedAt: Date? = nil
  ) {
    self.id = id
    self.relyingPartyIdentifier = relyingPartyIdentifier
    self.userHandle = userHandle
    self.userName = userName
    self.userDisplayName = userDisplayName
    self.credentialId = credentialId
    self.privateKeyPKCS8 = privateKeyPKCS8
    self.signCount = signCount
    self.createdAt = createdAt
    self.lastUsedAt = lastUsedAt
  }

  /// The relying party's site, derived from ``relyingPartyIdentifier`` for display (the detail
  /// card's "website" field) — `rpId` is a registrable domain, so `"https://" + rpId` is always a
  /// well-formed URL to show or open.
  public var website: URL? {
    URL(string: "https://\(relyingPartyIdentifier)")
  }

  /// The display name shown in list rows and the detail card: ``userDisplayName`` if the relying
  /// party gave one, otherwise ``userName``.
  public var displayName: String {
    userDisplayName.isEmpty ? userName : userDisplayName
  }
}
