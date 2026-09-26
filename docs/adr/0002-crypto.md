# 0002. Crypto design: key hierarchy, unlock methods, recovery

**Status: Proposed — needs external review.**

Related: [851-2446](https://linear.app/851/issue/851-2446/crypto-design-adr-key-hierarchy-unlock-methods-recovery). Written before `VaultStore` is built, per the [project decisions](https://linear.app/851/project/lil-passwords-ceedf3416b9d): macOS 13+, Swift 6, AppKit, a **fully local MVP** (no accounts, no server, no iCloud, no network requests that touch vault data), an encrypted SQLite vault, a `LilPasswordsAgent` helper that owns the vault key and serves XPC, and `lilpw`/MCP talking to the helper.

This ADR covers what ships in the MVP (implemented alongside this doc, in `LilPasswordsKit`'s `VaultCrypto`) and what's designed but deliberately **not built yet** for "Sync & web" and "Later" (marked as such throughout).

## Decision

### No master password

The MVP has **no master password** and no user-chosen passphrase anywhere in the key hierarchy. The vault key is 256 bits of randomness generated once, on first launch, and never derived from anything a person has to remember or type.

This is a deliberate simplification, not an oversight — see [Alternatives considered](#alternatives-considered). It also answers the "master password?" question the ticket asked: **no**.

### Key hierarchy

```
                    ┌─────────────────────┐
                    │   Vault key (256b)  │  random, generated once
                    └──────────┬──────────┘
              ┌────────────────┼────────────────────┐
              │                │                     │
       stored in           wrapped under      (future) wrapped under
    local Keychain      a recovery key      an ephemeral X25519 secret
   (per-Mac, no iCloud)  (in the DB header)   (device approval handshake)
              │                │                     │
              └────────────────┴─────────────────────┘
                                │
                     seals every item directly
                    (AES-256-GCM, unique nonce
                     + per-row AAD, no per-item
                            keys)
```

- **Vault key.** One random 256-bit `SymmetricKey` per vault, identified by a `keyId` (`UUID`). It is the only symmetric secret in the MVP. It never leaves `LilPasswordsAgent`'s memory while the vault is unlocked, except to be written to the Keychain or wrapped for the recovery kit.
- **Per-item keys: no.** Items are sealed directly under the vault key, not under item-specific keys. A separate key per item (or per record type) would add real complexity — a key registry, more rotation surface, more places to get wrapping wrong — for a benefit AES-GCM's nonce and AAD already provide: encrypting a thousand rows under one key with unique random nonces does not weaken any individual ciphertext, and binding each seal to its row via AAD (below) already stops ciphertext from one row being replayed into another. If a future need appears (e.g., sharing a single item without sharing the whole vault key), we can introduce per-item keys then, encrypted under the vault key, without changing the vault key itself.
- **Account key pair — *(designed, not built; "Sync & web" milestone).*** An asymmetric key pair (X25519 for key agreement, Ed25519 for signing device-approval records) tied to the user's account once there is an account. Used to encrypt a shared group's symmetric key to each member's device, and to sign "this device is approved" records. Nothing about the MVP's local-only vault key depends on this key existing.

### Sealing items

Every item is sealed independently with **AES-256-GCM** (`CryptoKit`) under the vault key:

- **Nonce:** a fresh random 96-bit nonce per seal call (`AES.GCM.seal`'s default). Never reused, never derived — with a random vault key and random nonces there's no realistic path to nonce collision within a single vault's lifetime.
- **AAD (associated data):** `recordId`, `type`, and `schemaVersion`, encoded as a small length-prefixed binary blob (`VaultCrypto.AAD`) and authenticated — but not encrypted — alongside the ciphertext. This means:
  - Ciphertext from one row can't be copied into another row's column and successfully decrypt, even under the same vault key.
  - Ciphertext can't be replayed into a column of a different item type.
  - A ciphertext written under schema version 1 fails to open once the caller expects schema version 2, forcing an explicit migration step instead of silently misreading old bytes as a new shape.
- **Envelope (`VaultCrypto.SealedItem`):** stores `formatVersion`, `keyId`, and the AES-GCM `combined` output (nonce ‖ ciphertext ‖ tag). `keyId` says which vault key sealed this row, so `VaultStore` can support rotation (below) without a flag day, and `formatVersion` lets the sealing scheme itself change later without a flag day either.

`VaultCrypto.seal`/`VaultCrypto.open` implement exactly this and are the whole of the MVP's item-encryption surface; `VaultStore` (a later ticket) is expected to call them per column, constructing `AAD` from the row's own plaintext `recordId`/`type`/`schemaVersion` columns.

### Unlock methods

| Method | Where | MVP? |
| --- | --- | --- |
| Local (non-synced) Keychain | Every Mac | ✅ Built as part of the keychain/signing spike (851-2402/851-2400); this ADR specifies the design it implements. |
| Recovery key | Everywhere | ✅ `VaultCrypto.RecoveryKey` + `wrapKey`/`unwrapKey`, in this ticket. |
| Passkey (WebAuthn PRF) | Web vault | 🔜 Designed below; not built ("Sync & web"). |
| Approval from an existing device | New devices | 🔜 Designed below; not built ("Sync & web"). |

**Local Keychain (Mac).** The vault key's raw bytes are stored as a Keychain item scoped `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — available only while the Mac is unlocked, and, critically, **never included in an iCloud Keychain sync circle or a device backup that would carry it off-device**. Access is additionally gated by a `SecAccessControl` requiring Touch ID/user presence, so a process other than `LilPasswordsAgent` can't silently read it via a generic Keychain query. Only `LilPasswordsAgent` holds an unwrapped copy in memory once the user has unlocked; `lilpw` and the app never touch the Keychain item directly, they ask the agent over XPC.

**Recovery key.** 160 bits of randomness (`VaultCrypto.RecoveryKey`), shown to the user once, at vault creation, as grouped, human-transcribable **Crockford Base32** (excludes the visually ambiguous `I`, `L`, `O`, `U`) with a trailing CRC-8 checksum byte, e.g. `4S9K-D2XQ-7RTN-…`. The checksum catches the overwhelming majority of single-character copying mistakes before the user walks away from the recovery card thinking they wrote it down correctly.

The vault key is wrapped under a key **HKDF**-derived from the recovery key's raw entropy (`HKDF<SHA256>`, random 128-bit salt per wrap, AES-256-GCM to actually wrap the key bytes), and that wrapped copy (`VaultCrypto.WrappedKey`) lives in the vault database's header, next to the SQLite file. **The recovery key plus the vault file is sufficient to restore the vault — no other device, no server, no account required.** This is deliberate: it's the MVP's only "new Mac" story, and it must work standalone.

Because the recovery key is machine-generated 160-bit randomness rather than something a user chose, **HKDF alone is the right derivation** here — no memory-hard password KDF (Argon2id, scrypt) is needed, since those exist specifically to slow down guessing *low*-entropy secrets, and 160 random bits already aren't guessable. If the product ever adds an *optional* user-chosen master password later, that's a different secret with different entropy characteristics and would need its own KDF decision at that time — it should not be retrofitted onto the recovery key's HKDF.

**Passkey with WebAuthn PRF — *(designed, not built; web vault, "Sync & web" milestone).*** The web vault unlocks via a passkey's PRF extension: the browser calls WebAuthn's `getClientExtensionResults().prf` to get a per-credential secret, feeds it through HKDF (`WebCrypto`, mirroring the Mac's `CryptoKit` HKDF call) to derive a wrapping key, and unwraps a copy of the vault key that a sync server relays as ciphertext only. **This is a web-only unlock method in the MVP-plus-sync design**, not a Mac one: native passkey PRF via `AuthenticationServices` needs macOS 15+, and the deployment target is macOS 13, so the Mac cannot depend on it. The Mac keeps using the local Keychain regardless of what ships on the web.

**Approval from an existing device — *(designed, not built; "Sync & web" milestone).*** A new device (Mac or browser) generates an ephemeral X25519 key pair and presents its public key, out-of-band (e.g., a QR code scanned by the existing device, or a numeric code compared on both screens) to prevent a server-in-the-middle from substituting its own key. The existing, already-unlocked device performs ECDH against that ephemeral public key, derives a transport key via HKDF, and uses it to encrypt the vault key to the new device. The sync server only ever relays that ciphertext; it never sees the vault key or the ECDH shared secret. The existing device also signs an "I approved this device" record with the account's Ed25519 key, so approvals themselves are auditable and revocable (see below) independent of the sync server's honesty.

### Rotation and device revocation — *(designed now, not exercised until `VaultStore`/sync exist)*

- **Vault key rotation:** generate a new `VaultCrypto.Key` (`keyId` B), re-seal every row under it (each seal naturally gets a fresh nonce and the row's existing AAD), re-wrap it for the recovery key, and re-store it in the Keychain, all before deleting key A. Because `SealedItem.keyId` travels with each row, a rotation can proceed row-by-row rather than atomically flipping the whole vault, and a crash mid-rotation just leaves some rows on key A and some on key B, both of which remain openable until the caller finishes and deletes key A.
- **Device revocation *(post-MVP, once there are multiple devices):*** revoking a device means the account's Ed25519/X25519 material is rotated and the revoked device's approval record is invalidated; it does **not** by itself change the vault key, since the vault key already left that device's control the moment it was revoked in this design — a revoked device that already has the vault key can still decrypt data it already synced (a real limitation, and the reason vault key rotation exists as a stronger, explicit remedy for a device believed to be compromised rather than merely removed).

### What a compromised server can learn — *(post-MVP; server doesn't exist yet)*

The sync server only ever stores ciphertext: sealed items, `WrappedKey` blobs, and approval records — never plaintext vault contents, the vault key, or the recovery key. It necessarily can observe metadata: which account owns which encrypted blobs, blob sizes (bucketable but not eliminable — a 4096-byte-padded scheme is a reasonable future mitigation, not an MVP concern), write timestamps and frequency (revealing usage patterns), device count and approval events, and IP addresses at connection time. None of this is addressed by AES-GCM; it's an explicit accepted limitation of a server-relay sync design, called out here so it isn't rediscovered as a surprise later.

## Threat model

| Threat | Exposure | Mitigation |
| --- | --- | --- |
| **Stolen Mac** | Attacker has the disk and the Keychain database. | The Keychain item requires the device to be unlocked and Touch ID/user presence to read; FileVault (assumed on) protects the disk at rest. The vault key never sits in a form that's readable from disk without going through the Keychain's own access control. The recovery key is not stored on the Mac, so possessing the stolen Mac alone doesn't yield it. |
| **Malicious local process while unlocked** | Runs as the same user, while `LilPasswordsAgent` holds the unwrapped vault key. | **By design, this is not mitigated.** The MVP's whole "agents can read everything with no prompts while unlocked" feature *is* this threat, accepted deliberately (per the project decisions) in exchange for a frictionless local-agent/MCP experience. The mitigations that exist are a Settings toggle to disable agent access and a mandatory access log — not cryptographic barriers, since a process with the same user's privileges can, in the limit, attach to or inspect `LilPasswordsAgent` regardless of what the agent's XPC policy says. Locking the Mac (or the vault) removes the exposure by removing the unwrapped key from memory. |
| **Compromised sync server *(post-MVP)*** | Operator or attacker controls the server. | Never sees plaintext, the vault key, the recovery key, or ECDH shared secrets — only ciphertext, `WrappedKey` blobs, and the metadata in [what a compromised server can learn](#what-a-compromised-server-can-learn---post-mvp-server-doesnt-exist-yet). It can deny service, corrupt or roll back ciphertext (mitigated by the item's own AEAD tag catching tampering, and by versioned/tombstoned records catching rollback at the `VaultStore` layer, not this one), or attempt to inject a fraudulent device-approval request — the out-of-band comparison step in device approval exists specifically to stop a server from puppeting that flow. |
| **Lost recovery key + lost Mac** | No cryptographic mitigation — this is unrecoverable data loss by design. | Out of scope for this ADR; a product-level warning at recovery-kit creation time is the mitigation. |

## Alternatives considered

- **A master password deriving (or gating) the vault key.** Rejected for the MVP: it reintroduces a rememberable secret exactly where the project's stated goal was frictionless local unlock via Keychain/Touch ID, adds a slow-KDF decision and a "forgot password" story that the recovery key already covers better, and buys no security the local Keychain's own access control doesn't already provide against the threats in scope (a master password mainly helps against a *stolen unlocked Keychain*, which isn't materially different from a stolen unlocked Mac here). It can be revisited as an opt-in extra factor without disturbing this design, since it would layer on top of, not replace, the vault key.
- **Per-item keys.** Rejected for the MVP as unneeded complexity — see [key hierarchy](#key-hierarchy) above.
- **A single "master secret" that both unlocks locally and wraps for recovery via the same derivation.** Rejected: conflating the two collapses the local Keychain's hardware-backed access control into "whatever the recovery key's math says," which is strictly weaker than having two independent unlock paths that don't need each other.

## Consequences

- `VaultStore` (next) can be built directly against `VaultCrypto.seal`/`open`, constructing `AAD` from each row's own plaintext `recordId`/`type`/`schemaVersion` columns.
- The recovery kit (a future UI ticket) needs only `VaultCrypto.RecoveryKey.generate()`, its `displayString`, and `VaultCrypto.wrapKey`, storing the resulting `WrappedKey` in the database header.
- The Keychain-storage half of "local Keychain unlock" is implemented separately (851-2402/851-2400); this ADR is what that work should match.
- Nothing here blocks "Sync & web" from later adding passkey PRF, device approval, or an account key pair — none of the MVP's types assume they don't exist, and none of the "Sync & web" design depends on changing the vault key's own representation.

## Open questions for external review

- Is Crockford Base32 + a single CRC-8 byte enough error-detection for a recovery key printed on paper, or should the checksum be stronger (e.g., a full CRC-16, or a check computed over grouped characters the way Crockford's spec suggests)?
- Is 160 bits the right floor for the recovery key given it's the *only* backstop for "lost Mac," or should the MVP go to 192/256 bits given the low cost of a longer string?
- Does the "malicious local process while unlocked" acceptance need a stronger mitigation sooner than the roadmap currently plans (e.g., per-agent approval prompts before general availability), given it's the most concretely exploitable threat in this table?
