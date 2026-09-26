# 0005. AutoFill credential provider

- Status: Accepted
- Related: [851-2441](https://linear.app/851/issue/851-2441) (this work), [851-2400](https://linear.app/851/issue/851-2400)
  (signing/entitlements — the open blocker this ADR documents), [851-2427](https://linear.app/851/issue/851-2427)
  (XPC), [851-2428](https://linear.app/851/issue/851-2428)/[851-2433](https://linear.app/851/issue/851-2433)
  (agent-access settings), ADR 0001 (storage and process model — the "only the helper opens the
  vault" rule this ADR extends to a third peer)

## Context

lil passwords needs to appear as a password source in Safari and system AutoFill. macOS exposes
this via an `ASCredentialProviderViewController` app extension, embedded in the app, registered
under the `com.apple.authentication-services-credential-provider-ui` extension point. Per ADR
0001, only `LilPasswordsAgent` ever opens the vault; every other process — the app, `lilpass`, and
now this extension — talks to it exclusively over XPC. This extension is the first genuinely new
trust boundary since that ADR: a third XPC peer, and the first *sandboxed* process in this
codebase (App Sandbox is mandatory for any extension, unlike the app itself, which ADR 0001
deliberately left unsandboxed).

## 1. Trust model: a third peer, structurally narrower than the app

The extension needs to ask the helper for three things: "unlock" (gated by its own `LAContext`
prompt, same rationale ADR 0001 already established for the app), "which of my saved items match
these websites" (service identifiers + usernames only), and "give me this one item's
username+password" (exactly the one the user picked). It should never be able to reach
`.list`/`.search`/`.getItem`, or any create/update/delete operation — the ticket's own framing is
"treat it like the app for read access to the credential being filled, but gated so it can only
return the credential for the chosen identity."

That gate is enforced structurally, not just by policy:

- `AgentConnectionSecurity.PeerIdentifier` gains a third case, `.autoFill`
  (`com.851labs.lilpasswords.autofill`), verified via `NSXPCConnection.setCodeSigningRequirement(_:)`
  exactly like `.app`/`.cli` — a real signed build refuses a connection from anything that isn't
  actually the built extension's own signature, independent of anything below.
- `AgentServer.isRequestPermitted(_:for:)` runs before dispatch, before any
  `AccessPolicyProviding`/write-access check even gets a chance to run. For an AutoFill caller it
  allows only `.status`, `.unlock`, `.lock`, `.autoFillIdentities`, `.autoFillCredential`, and
  returns `.callerNotAuthorized` for literally everything else — including `.list`/`.search`/
  `.getItem`, which the app and CLI both reach freely. This means there is no code path inside the
  helper's dispatch switch that would return a second item's data (or any item's full record) to
  this caller, not merely a check that currently happens to say no.
- `.autoFillCredential(id:)`'s response type, `AgentResponse.autoFillCredential(username:,
  password:)`, carries nothing else about the item — no title, no website, no notes. Even if the
  gating above had a bug, the wire type itself can't leak more than a username+password pair for
  the one id requested. This mirrors `CredentialIdentity`'s own design (service+username only,
  never a password) for the list side.
- `AgentSettingsAccessPolicy.isAccessAllowed(for:)` treats the AutoFill caller the same exemption
  the app already gets from the 851-2428 "Allow agents to access passwords" toggle — that toggle is
  about third-party agent tools (`lilpass`/MCP), not the product's own UI surfaces, and AutoFill is
  the latter.
- The access log renders this caller as "AutoFill" with no new code at all:
  `CallerIdentityResolver`'s existing `proc_name` walk already shows whatever the connecting
  process is actually named, and the extension's `PRODUCT_NAME` is deliberately `AutoFill` — so
  `AccessLogEntry`'s existing caller-description logic satisfies the ticket's "log it in the access
  log as AutoFill" requirement without a special case for this one caller.

## 2. `ASCredentialIdentityStore` sync: keep it in sync, don't clear on lock

The system's own credential identity store (service identifiers + usernames, indexed by
`recordIdentifier`) is what lets AutoFill offer lil passwords *before* the extension is even asked
to do anything — it's how Safari knows to show "lil passwords" as an option, and how
`provideCredentialWithoutUserInteraction(for:)`/`prepareInterfaceToProvideCredential(for:)` get
invoked with a specific identity at all.

`ASCredentialIdentityStoreSync` (in `LilPasswordsKit`, behind the `CredentialIdentityStoreSyncing`
seam so the mapping logic is unit-testable without the real system store) maps every live item that
has both a resolvable website host and a non-blank username to one `ASPasswordCredentialIdentity`,
keyed by `PasswordItem.id.uuidString` — never a password, mirroring `CredentialIdentity`'s own
wire-type restriction. It's called from the app (`CredentialIdentityStoreSyncCoordinator`, wired
into `MainWindowController`) after the initial post-unlock list load and on the app's own
`DarwinNotifications.vaultChanged` signal — never from the helper or the extension, so the "only
service+username, never a password" boundary is enforced by which process even has a password
available to include, not just by what the sync code chooses to send.

**Decision: sync on every vault change and post-unlock load; do not clear the identity store on
lock.** The store only ever holds non-secret service+username pairs — no more sensitive than what
AutoFill's own list UI already shows, or what any other password manager's provider keeps resident
for the same reason. It exists specifically so the system can invoke lil passwords' extension
*while the vault is locked*, routing through `provideCredentialWithoutUserInteraction(for:)`
(throws `.userInteractionRequired`) or `prepareInterfaceToProvideCredential(for:)` (shows this
extension's own Unlock button) for the actual lock-gated fetch. Clearing it on every lock — which
would otherwise happen on every auto-lock, i.e. constantly — would silently stop offering lil
passwords as a fill source across most of a normal session, for no corresponding security benefit:
the thing an attacker would actually want (the password) is never in the store to begin with.

## 3. Shared list row style

The ticket asks for `prepareCredentialList(for:)` to reuse "the existing list row style."
`ItemRowCellView` (the app's own list row) and `MonogramIcon` (its icon renderer) moved from the
app target into `LilPasswordsKit` as public types — `CredentialRowView`/`MonogramIcon` — since the
extension is a separate bundle with no access to the app target's sources, and has no full
`PasswordItem` to render anyway (only the narrower `CredentialIdentity` the helper hands back).
`CredentialRowView.configure(title:subtitle:hidesSeparator:)` is the primitive both the app (via a
`PasswordItem`-specific convenience overload) and the extension use, so the two lists render
identically without duplicating the drawing code.

## 4. Provisioning-profile blocker (documented for Alexandru, 851-2400)

Both entitlements this extension needs —
`com.apple.developer.authentication-services.autofill-credential-provider` and, transitively, app
extensions' general provisioning requirements — are the same class of *restricted* entitlement ADR
0001 already found for `keychain-access-groups`: AMFI/Xcode's build system require a real
provisioning profile from the signing team, which doesn't exist until the 851 Labs Apple Developer
Program team is set up. Confirmed empirically this session:

- `xcodebuild` refuses to even build the `AutoFillExtension` target under this project's normal
  `CODE_SIGN_STYLE = Manual` / ad-hoc identity settings, with `"AutoFillExtension" requires a
  provisioning profile. Enable development signing and select a provisioning profile...` —
  regardless of the ad-hoc identity, because the entitlement itself is what triggers the profile
  requirement, not the choice of signing identity.
- Worked around, for CI/build-only purposes, by setting `CODE_SIGNING_ALLOWED: NO` on just this
  target (`project.yml`) — this skips Xcode's own build-time codesign step for the target (which is
  what enforces the profile requirement), while the plain `codesign` CLI invoked afterward (this
  target's `copy: destination: plugins, codeSign: true` embed step) signs it ad-hoc with its real
  entitlements the same way every other target in this project is signed, with no profile
  requirement of its own. `make build` and CI stay green; the produced `.appex` is fully embedded
  and carries its real entitlements.
- This does **not** make the extension actually usable locally: AMFI will refuse to let an
  ad-hoc-signed binary carrying a restricted entitlement actually register as a credential provider
  at runtime (the same failure mode ADR 0001 found for `keychain-access-groups`, just surfacing at
  "enable in System Settings" instead of "process launch"). Tophat for this ticket documents the
  exact point this blocks at, rather than a working Safari AutoFill demo.
- **Action needed from Alexandru**: once the 851 Labs Apple Developer Program team exists
  (851-2400), a provisioning profile covering the AutoFill credential provider capability needs to
  be created and installed locally (and eventually wired into `scripts/release/sign.sh` for
  release builds) before this extension can be enabled and tested end-to-end.

## Alternatives considered

- **An App Group, instead of `com.apple.security.temporary-exception.mach-lookup-global-name`, for
  the extension to reach the helper's Mach service.** Rejected for now: an App Group would require
  adding entitlements to the app/CLI/agent targets too (all currently empty, per those files' own
  comments), just to add one new sandboxed peer. The temporary-exception approach grants exactly
  one named Mach service lookup and nothing else, and every actual request over that connection is
  still gated by `AgentServer.isRequestPermitted(_:for:)` regardless of which mechanism opened the
  connection.
- **Clearing `ASCredentialIdentityStore` on lock.** Rejected — see §2.
- **Letting the extension call `.list()`/`.search()` directly and filter client-side.** Rejected:
  it would return every item's full record (including other websites/usernames/notes) to a
  sandboxed, third-party-adjacent trust boundary for no reason — `.autoFillIdentities` narrows the
  data at the source instead.

## Consequences

- The AutoFill extension builds and embeds in `make build`/CI today; it cannot be enabled or
  demonstrated end-to-end (Safari offering lil passwords) until 851-2400 produces a real
  provisioning profile — see §4 and the ticket's tophat notes.
- `CredentialRowView`/`MonogramIcon` are now public `LilPasswordsKit` API; any future third UI
  surface (e.g. a Quick Look extension) gets the same row style for free.
- The helper's peer set going from two to three code-signed identities is the template for any
  future sandboxed peer (e.g. a Safari Web Extension, if ever added) — `isRequestPermitted(_:for:)`
  is the place a fourth peer's allowed operation set would be declared.
