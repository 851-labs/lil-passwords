# 0008. Passkeys (macOS 14+)

- Status: Accepted
- Related: [851-2442](https://linear.app/851/issue/851-2442) (this work), ADR 0001 (storage and
  process model — "only the helper opens the vault"), ADR 0002 (crypto — how `PasskeyItem`'s
  private key is sealed), ADR 0005 (AutoFill credential provider — the extension and XPC trust
  boundary this ticket adds two ops to)
- Numbered 0008 rather than 0007 (this ticket's own first choice) to leave 0007 for 851-2445's
  scoped agent access ADR, which claims it independently on its own branch.

## Context

lil passwords already fills passwords via the `AutoFillExtension` added in ADR 0005. Safari/system
AutoFill also wants lil passwords to be able to *create and use passkeys* — WebAuthn public-key
credentials — for sites that support them. macOS exposes this through the same
`ASCredentialProviderViewController` extension point, via `ASCredentialProviderExtension`'s
passkey-specific hooks (`prepareInterface(forPasskeyRegistration:)`,
`prepareCredentialList(for:requestParameters:)`,
`provideCredentialWithoutUserInteraction(for:)`) once the extension sets `ProvidesPasskeys` in its
`Info.plist`.

The minimum OS is macOS 13 (ADR 0005); the passkey APIs above are macOS-14-only. Every symbol this
ticket touches in the extension is therefore `@available(macOS 14, *)`, and the app's Passkeys
sidebar category degrades to an explanatory empty state on 13 rather than a broken list.

## 1. `PasskeyItem`: a new record type, sealed like every other secret

A passkey is modeled as its own `PasskeyItem` (`Packages/LilPasswordsKit/Sources/LilPasswordsKit/Item/PasskeyItem.swift`),
not shoehorned into `PasswordItem`: relying party identifier, user handle, user name/display name,
credential id, a P-256 private key (PKCS8), a sign count, and created/last-used dates. It gets its
own `VaultRecord` case and schema version (`PasskeyItemSchema.swift`), with migration tests the
same shape as every prior schema bump (ADR 0003) — additive, so an older helper build opening a
vault a newer one wrote to ignores the new record type rather than failing to open it.

`privateKeyPKCS8` is sealed exactly like `PasswordItem.password` (ADR 0002: AES-256-GCM under the
vault key) and, per the ticket's core constraint, is retrievable in decrypted form *only* inside
`LilPasswordsAgent`. Nothing outside the helper — not the app, not `lilpass`, not the AutoFill
extension, not an MCP agent — ever receives it. `PasskeyMetadata` (the shape every reader actually
gets back: relying party, user name/display name, website, created/last-used — no key, no sign
count) is the structural enforcement of that: the type returned to callers simply has no field to
carry the key in.

## 2. Signing stays in the helper; two new AutoFill-only XPC ops

Registration and assertion both need the private key. Per ADR 0001/0005's existing rule, that means
neither can happen in the (sandboxed, third-party-adjacent) extension process — the extension asks
the helper to do the cryptographic operation and hands back only the result.

Two new `AgentRequest` cases, `passkeyRegister` and `passkeyAssert`, join the AutoFill-only
allow-list in `AgentServer.isRequestPermitted(_:for:)` alongside the existing
`autoFillIdentities`/`autoFillCredential` pair:

```swift
case .status, .unlock, .lock, .autoFillIdentities, .autoFillCredential, .passkeyRegister, .passkeyAssert:
```

- `passkeyRegister(relyingPartyIdentifier:userHandle:userName:)` — the helper generates a fresh
  `P256.Signing.PrivateKey` (CryptoKit), builds a "none"-attestation attestation object and
  `authenticatorData` (`PasskeyAuthenticator.swift` — pure functions, no vault/XPC awareness, unit
  tested directly), stores a new sealed `PasskeyItem`, and returns just the public credential
  (id, public key, attestation object) — never the private key — as
  `PasskeyRegistrationResult`/`.passkeyRegistered`.
- `passkeyAssert(credentialId:clientDataHash:)` — the helper looks up the matching `PasskeyItem` by
  credential id, signs `clientDataHash ‖ authenticatorData` with the stored private key, increments
  and persists `signCount`, and returns the signature/authenticatorData as
  `PasskeyAssertionResult`/`.passkeyAsserted`. The private key is read from the sealed vault index
  and used in-process; it's never serialized onto the XPC connection in either direction.

Both ops are rejected for every other caller (the app, `lilpass`, or any other identity) the same
way `autoFillIdentities`/`autoFillCredential` already are — see `AgentServerTests` for the
allow-list assertions this ticket adds alongside the existing ones.

**Security review fix:** `isRequestPermitted(_:for:)`'s AutoFill allow-list only ever *narrows*
that one caller's own connection — every other caller falls through to `return true` and is
gated by whatever the individual request handler in `vaultResponse(for:caller:)` checks instead
(`requireWriteAccess(for:)`, the 851-2433 write-access toggle). `passkeyRegister`/`passkeyAssert`
first shipped that way too, which meant that with agent write access turned on, `lilpass` (or any
code-signing-verified peer) could ask the helper to sign a WebAuthn assertion for *any* relying
party — a full "log in as this person anywhere" primitive, with no Touch ID and no system UI. Fixed
by making `isRequestPermitted(_:for:)` hard-refuse both ops with `.callerNotAuthorized` for every
caller except the verified AutoFill connection, structurally, before `requireWriteAccess(for:)` (a
disableable settings toggle meant for `PasswordItem` CRUD, not "sign into anywhere") ever runs —
the system's own AutoFill picker UI is the real, non-bypassable user-presence gate for these two
ops. `.deletePasskey` got the same treatment for a simpler reason: agents never manage passkeys at
all, full stop, so it's gated by `isAppCaller(_:)` directly rather than the write-access toggle
that lets `lilpass` delete ordinary `PasswordItem`s. See `AgentServerTests`' `lilpassAndAppCallers…`/
`deletePasskeyIsAppOnly…` tests, which assert `.callerNotAuthorized` even with write access
explicitly turned on.

The UV (user-verified) authenticatorData flag also stopped being hardcoded `true`: it now reads
`PasskeyRegistrationRequest.userVerified`/`PasskeyAssertionRequest.userVerified`, which
`CredentialProviderViewController` sets to `true` only when it just ran its own `LAContext`
ceremony (the post-"Unlock…"-button retry path) and `false` for the direct
`provideCredentialWithoutUserInteraction(for:)`/`prepareInterface(forPasskeyRegistration:)` entry
points, where no such ceremony happens in this process.

The extension's `prepareInterface(forPasskeyRegistration:)` and
`provideCredentialWithoutUserInteraction(for:)`/`prepareCredentialList(for:requestParameters:)`
implementations are thin: build the request, call the helper, wrap the result as an
`ASPasskeyRegistrationCredential`/`ASPasskeyAssertionCredential`. The identity store side
(`ASPasskeyCredentialIdentity`, feeding `CredentialIdentityStoreSyncCoordinator` from ADR 0005) only
ever carries relying party/user/credential-id metadata — structurally, like
`ASPasswordCredentialIdentity` before it, it has no field for a secret.

## 3. App: list + detail, metadata only

The Passkeys sidebar category (`App/Sources/MainWindow/Passkeys/`) lists passkeys by site and user,
reading through `AgentClient.passkeys()` — which, like every other agent-facing read, only ever
receives `PasskeyMetadata`. The detail card shows website, user name, created date, and a Delete
button (`PasskeyDetailViewController`/`PasskeyDeleteConfirmation`); delete calls
`AgentClient.deletePasskey(id:)` and the list is refreshed both locally (immediately, its own write)
and via `DarwinNotifications.vaultChanged` (so an AutoFill-driven registration/assertion elsewhere
shows up without polling — see `PasskeysViewModel.startObservingVaultChanges()`).

Per the ticket, agents (`lilpass`/MCP) get list metadata only when agent access is enabled, and
never key material — enforced the same way as the app: `AgentClient.passkeys()`'s return type is
`PasskeyMetadata`, full stop.

### macOS 13

The passkey extension hooks are macOS-14-only, but the app itself still supports macOS 13 (ADR
0005). On 13, the Passkeys category is still selectable in the sidebar, but shows an explanatory
empty state (no list, no "0 Passkeys" claim) rather than attempting a feature the OS can't back —
the same shape as the extension-side `@available` gating, just surfaced as a sentence instead of a
compile-time guard.

## 4. Testing a real webauthn.io registration (documented, not performed)

The ticket asks for a real `webauthn.io` registration round trip as part of tophat. That requires
the AutoFill extension to actually be enabled as a credential provider in System Settings, which —
per ADR 0005 §4 — is blocked on a real provisioning profile for the
`com.apple.developer.authentication-services.autofill-credential-provider` entitlement, which in
turn is blocked on the 851 Labs Apple Developer Program team existing (851-2400/851-2441). That
blocker is unchanged by this ticket: it's the same entitlement, the same extension, the same
ad-hoc-signing limitation (AMFI refuses to let an ad-hoc-signed binary carrying this entitlement
register at runtime), just exercised by a second capability (`ProvidesPasskeys`) instead of the
first.

What the flow *would* look like, once that profile exists:

1. Enable lil passwords as a password/passkey AutoFill provider in System Settings → General →
   Login Items & Extensions → AutoFill Extensions (as ADR 0005 documents for password AutoFill).
2. Visit `https://webauthn.io`, enter any username, click "Register". Safari/AutoFill calls
   `prepareInterface(forPasskeyRegistration:)`; the extension asks the helper for
   `passkeyRegister`, gets back an `ASPasskeyRegistrationCredential`, and webauthn.io's server
   verifies the attestation object (format `"none"`, so it only checks structure, not a signed
   attestation chain) and stores the public key.
3. Click "Login" with the same username. Safari calls
   `provideCredentialWithoutUserInteraction(for:)`/`prepareCredentialList(for:requestParameters:)`;
   the extension asks the helper for `passkeyAssert`, gets back an `ASPasskeyAssertionCredential`,
   and webauthn.io's server verifies the signature over `clientDataHash ‖ authenticatorData` against
   the public key it stored in step 2, and checks the returned sign count moved forward.
4. Confirm the new passkey appears in the app's Passkeys list (site "webauthn.io", the username
   entered) without the app process having done anything — the registration was entirely
   extension → helper, surfaced to the app only via `DarwinNotifications.vaultChanged`.

Until the profile exists, this ticket's tophat substitutes DEBUG sample passkeys
(`-PasskeysDebugSampleData YES`) for the app-side list/detail UI, and the unit tests in §5 for the
protocol-level correctness a live webauthn.io round trip would otherwise be the only way to check.

## 5. Tests

- `PasskeyRecordCodecTests` — `PasskeyItem` ↔ sealed `VaultRecord` round trip, schema version,
  migration.
- `PasskeyAuthenticatorTests` — `authenticatorData` encoding (rpIdHash, UP/UV/AT flags, big-endian
  signCount, attested credential data with a COSE EC2 key), attestation object shape, and a full
  sign/verify round trip using the same P-256 key.
- `AgentServerTests` — `passkeyRegister`/`passkeyAssert` added to the AutoFill-only allow-list
  assertions; rejected for every other caller identity, **including with agent write access turned
  on** (`lilpassAndAppCallersAreRejectedForPasskeyRegisterAndAssertEvenWithWriteAccessOn`); the same
  for `.deletePasskey` being app-only (`deletePasskeyIsAppOnlyEvenWithWriteAccessOn`); and that the
  UV flag reflects `PasskeyAssertionRequest.userVerified` rather than a hardcoded value
  (`passkeyAssertReportsUserVerifiedOnlyWhenTheRequestSaysSo`).

## Consequences

- A fourth record type (after passwords, Wi-Fi networks per ADR 0006, and whatever TOTP secrets
  already were) that only the helper ever decrypts, extending ADR 0001's rule rather than carving
  out an exception to it.
- Two new entries in `AgentServer.isRequestPermitted(_:for:)`'s AutoFill allow-list; any future
  passkey-adjacent op (e.g. explicit credential deletion from the extension, not currently needed)
  would be declared the same way.
- A real end-to-end webauthn.io demo remains blocked on 851-2400/851-2441's provisioning profile,
  same as ADR 0005's password AutoFill demo — §4 is this ticket's version of ADR 0005 §4's note for
  Alexandru.
