# 0001. Storage and process model

- Status: Accepted
- Related: [851-2402](https://linear.app/851/issue/851-2402) (this spike), [851-2400](https://linear.app/851/issue/851-2400) (signing/entitlements), [851-2427](https://linear.app/851/issue/851-2427) (XPC, not yet scheduled at time of writing)

## Context

The project's shape is: **LilPasswords.app** (AppKit UI), **LilPasswordsAgent** (a
per-user login-item helper registered with `SMAppService`, which is meant to own
the unlocked vault key and serve requests over XPC), and **lilpw** (a CLI + MCP
server that talks to the helper). All three need to agree on where the vault
database lives, where the vault key lives, whether a Touch ID prompt can come
from the helper, and how they learn about each other's writes — before any of
that gets built for real.

The MVP is **100% local**: no accounts, no server, no iCloud, and the app is
Developer ID-distributed (not Mac App Store) — Sparkle updates and unrestricted
XPC/CLI access both push away from App Sandbox. The 851 Labs Apple Developer
Program team does not exist yet (see [851-2400](https://linear.app/851/issue/851-2400));
today's builds sign with a personal team via a gitignored `Config/Local.xcconfig`.

All claims below marked **(tested)** were verified with small throwaway Swift
programs (`swiftc` one-offs and a temporary hook in `AppDelegate` that was
reverted before this branch's real commits) built and run on this machine
(macOS 27, Xcode 27, Swift 6.4). Claims marked **(documented)** are
well-established platform behavior cited from Apple's docs/forums but not
independently re-verified here (mostly because reproducing them would require
things this spike doesn't have, like a provisioning profile or a second Mac).

## (a) Can the helper store/read a non-synced vault-key item, and does the app need direct Keychain access?

macOS has two independent keychains behind the same `SecItem*` API:

- **The legacy file-based keychain** (`~/Library/Keychains/login.keychain-db`).
  Access control is ACL-based (a per-item trusted-application list), not
  entitlement-based. Selected by default, or explicitly with
  `kSecUseDataProtectionKeychain: false`.
- **The data-protection (DP) keychain**, the iOS-style keychain brought to
  macOS for iCloud Keychain. Access control is `keychain-access-groups` +
  `SecAccessControl`, driven entirely by code-signing entitlements. Selected
  with `kSecUseDataProtectionKeychain: true` — and, we found, implicitly
  whenever a query includes `kSecAttrAccessControl` at all (see (b)).

**(tested)** A plain `SecItemAdd`/`SecItemCopyMatching` generic-password
round-trip on the **legacy keychain** succeeds from a completely unsigned
binary, no entitlements, no provisioning profile:

```
SecItemAdd (legacy keychain) status: 0 (No error.)
SecItemCopyMatching (legacy keychain) status: 0
Read back: vault-key-bytes
```

**(tested)** The same call with `kSecUseDataProtectionKeychain: true` fails
with `errSecMissingEntitlement` (-34018) — and this doesn't improve with
signing, only with a genuine entitlement + provisioning profile (see (c)):

```
unsigned:                          -34018 (A required entitlement is not present.)
ad-hoc signed:                     -34018 (A required entitlement is not present.)
signed, Apple Development, no ent: -34018 (A required entitlement is not present.)
```

**Does the app need direct Keychain access? No.** The simplest design, and the
one this spike recommends, is: **only `LilPasswordsAgent` ever calls
`SecItem*`.** It stores the vault key as a generic-password item in its own
process's legacy keychain, using no entitlement and no access group. The app
and `lilpw` never touch the Keychain — they ask the helper for a session over
XPC instead. This sidesteps cross-process Keychain sharing entirely (no
`keychain-access-groups`, no provisioning profile, no dependence on the 851
Labs team existing) and reduces the blast radius of a bug: there is exactly
one process in the system that can ever read the raw vault key.

The trade-off: if we ever want the *app* to read the vault key directly
(e.g. to avoid an XPC round trip), that's a separate, larger change gated on
having the 851 Labs team and a `keychain-access-groups` entitlement + matching
provisioning profile for both targets. Not needed for MVP; tracked as a
follow-up, not blocking.

## (b) Can that item use `.userPresence`, and can a background helper show the Touch ID prompt?

**(tested)** `SecAccessControlCreateWithFlags(_, _, .userPresence, _)` combined
with `kSecAttrAccessControl` **implicitly routes to the DP keychain** on this
OS version, even without setting `kSecUseDataProtectionKeychain` explicitly —
`SecItemAdd` failed with the same `errSecMissingEntitlement` (-34018) as
above. Forcing `kSecUseDataProtectionKeychain: false` alongside the access
control makes the *add* succeed on the legacy keychain with no entitlement:

```
SecItemAdd (userPresence, forced legacy keychain) status: 0 (No error.)
```

But reading that item back on the legacy keychain, even asking the (deprecated)
`kSecUseAuthenticationUI: .fail` to suppress UI and fail fast, did not return
promptly — the call **blocked** and had to be killed after 120s, never
printing a result. This is a meaningfully different (and worse) enforcement
path than the DP keychain, where the entitlement check happens deterministically
and synchronously *before* any UI is even considered. We could not get a clean,
reliable "fail immediately, no UI" behavior for a `.userPresence` item on the
legacy keychain in this environment.

**Would a background `LaunchAgent` even be allowed to show the prompt?**
**(documented, not independently tested — no way to press Touch ID here):**
Apple's docs are consistent on this: the DP keychain "is only available in a
user login context, not from a launchd system daemon" — meaning the relevant
distinction isn't "foreground app vs. background process," it's **LaunchAgent
(per-user, runs inside the Aqua/WindowServer session) vs. LaunchDaemon (runs as
root, pre-login, no GUI session)**. `LilPasswordsAgent` is registered as an
**agent** (`SMAppService.agent`, `ProcessType: Interactive`), so it does run
inside the user's session and, per Apple's model, *can* trigger the system
Touch ID/password sheet when it accesses a `.userPresence`-protected DP
keychain item, exactly like a command-line tool or background agent can today
(e.g. `sudo`-adjacent tools, some password managers' helpers). The risk isn't
technical capability, it's UX and attribution: a system auth sheet popping up
with no window, initiated by a process the user doesn't recognize by name, and
(per our block-instead-of-fail-fast finding above) real risk of *hanging*
rather than cleanly erroring if the calling code gets the modern
`LAContext.interactionNotAllowed` / `kSecUseAuthenticationContext` incantation
slightly wrong.

**Recommendation, matching the fallback already named in this ticket:** don't
gate the vault key item itself with `.userPresence`. Instead:

1. The user unlocks in the **app** (which has a window, is frontmost, and is
   what the user just clicked on) via `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, ...)` (with an explicit
   passcode/password fallback — Touch ID isn't present/enrolled on every Mac).
2. The app hands the *result* of that evaluation to the helper over XPC.
   `LAContext` conforms to `NSSecureCoding` specifically to support passing an
   already-evaluated authentication context across a process boundary this
   way — this is Apple's documented pattern for "authenticate in one process,
   unlock a protected resource in another."
3. The helper stores/reads the vault key as a **plain** (no access-control)
   legacy-keychain item, protected only by the OS's normal keychain ACL (only
   `LilPasswordsAgent` is ever in its trusted-application list) — the
   biometric gate lives in the app's UX flow and the helper's session-lock
   policy, not in the keychain item's ACL.

This keeps the "who can physically press Touch ID" question entirely inside
the one process the user actually sees, and keeps the helper's Keychain calls
on the well-behaved, entitlement-free legacy path from (a).

## (c) Confirm the CLI must go through XPC

**(tested)** Yes, unconditionally. Beyond the -34018 failures above, we
signed a binary with a **real** `keychain-access-groups` entitlement (no
corresponding provisioning profile, since none exists yet):

```
codesign -s "Apple Development" -f --entitlements dp.entitlements ./dp_keychain
./dp_keychain
# process exit code: 137 (SIGKILL) — no output at all, not even our first print()
```

The process was killed by AMFI **before `main()` ran** — not a Keychain API
error, a launch-time policy kill. `keychain-access-groups` (like
`com.apple.security.application-groups` and other cross-process-sharing
entitlements) is a *restricted* entitlement: carrying it in your code
signature without a matching provisioning profile from the signing team gets
you killed outright, independent of whether you ever call a Keychain API.

The deeper reason `lilpw` specifically can never hold this, even once the 851
Labs team exists: a provisioning profile is embedded as a file
(`embedded.provisionprofile`) inside an application **bundle**. `lilpw` is a
bare Mach-O executable — whether it's sitting in `Contents/Helpers/lilpw`
inside the app bundle or installed standalone to `/usr/local/bin` (e.g. via
Homebrew) for scripting/agent use, it has no bundle of its own to embed a
profile in. So `lilpw` can never be granted a restricted entitlement, by
construction, not just "we chose not to." It must ask
`LilPasswordsAgent` — the one process that owns the vault key — for
everything, over XPC. `lilpw mcp` (the stdio MCP server) is the same binary,
same constraint.

## (d) Shared vault DB location and cross-process change notification

**Location:** an app-group container is an App Sandbox mechanism (it's how a
sandboxed app shares files with its sandboxed extensions, each normally
isolated in its own container). We're not sandboxing (see Context), so it buys
nothing here and would cost another restricted, profile-gated entitlement
(`com.apple.security.application-groups`) for no benefit. **Recommendation:**
a plain directory, `~/Library/Application Support/lil passwords/`, holding
`vault.sqlite`. The app and the helper both run as the same local user, so
normal POSIX file permissions are sufficient — no entitlement, no profile, and
it works from an ad-hoc/unsigned dev build too (matters for the "local dev
fallback" goal in [851-2400](https://linear.app/851/issue/851-2400)).

**Cross-process change notification:** **(tested)** Darwin notifications
(`CFNotificationCenterGetDarwinNotifyCenter`) deliver instantly between two
entirely unrelated, unsigned, unsandboxed processes with zero setup:

```
poster: posted
observer: waiting...
observer: received Darwin notification
```

Darwin notifications carry no payload and aren't restricted by App Sandbox
either way, so they're a good fit regardless of future sandboxing decisions.
**Recommendation:** the helper posts a Darwin notification (reverse-DNS name,
e.g. `com.851labs.lilpasswords.vaultChanged`) after every write; the app (and
any future long-lived `lilpw` process) observes it and re-reads the DB. We
don't need `NSFilePresenter`/file coordination — that machinery exists to
mediate *simultaneous* writers under sandboxed file coordination, and in this
design there's exactly one writer (the helper) and N read-only observers.

## Decision

1. **Only `LilPasswordsAgent` touches the Keychain.** It stores the vault key
   as a plain generic-password item in the **legacy** (file-based) keychain —
   explicit `kSecUseDataProtectionKeychain: false` everywhere, to avoid the
   implicit DP-keychain routing found in (b). No entitlement, no provisioning
   profile, no dependency on the 851 Labs team existing.
2. **No `.userPresence` access control on the keychain item.** Touch ID/password
   authentication happens in the app via `LAContext`, which then hands its
   evaluated session to the helper over XPC (851-2427 territory, but the shape
   is decided here).
3. **`lilpw` (and `lilpw mcp`) always go through XPC to the helper.** It never
   touches the Keychain or the vault DB file directly — structurally, not just
   by convention, since it can never hold a restricted entitlement.
4. **The vault DB lives at `~/Library/Application Support/lil passwords/vault.sqlite`,**
   no app group container, no App Sandbox.
5. **Cross-process change notification uses Darwin notify**
   (`com.851labs.lilpasswords.vaultChanged`), posted by the helper after every
   write, observed by the app.
6. **`keychain-access-groups` is deferred**, not designed around. If a future
   milestone needs the app to read the vault key directly, that's a new ADR,
   gated on the 851 Labs Apple Developer team and a provisioning profile.

## Infrastructure landed alongside this spike

- `Config/Entitlements/{App,Agent,CLI}.entitlements` — present and wired via
  `CODE_SIGN_ENTITLEMENTS` in `project.yml`, intentionally near-empty per the
  decision above (see comments in each file for why).
- `Agent/Support/com.851labs.lilpasswords.agent.plist` — the `SMAppService`
  launchd plist for the agent, embedded at
  `Contents/Library/LaunchAgents/` by `project.yml`. Uses `BundleProgram`
  (not `Program`/`ProgramArguments`) so the same plist works regardless of
  install location. No `RunAtLoad`/`KeepAlive`/`MachServices` yet — with no
  trigger, `launchd` registers the job but never runs it, which is fine: the
  agent has nothing to do until XPC (851-2427) adds a `MachServices` entry.
- `LilPasswordsAgent` and `lilpw` are both embedded at `Contents/Helpers/`
  (matching the plist's `BundleProgram`) rather than alongside the app's own
  executable in `Contents/MacOS`. They deliberately share one
  `destination`/`subpath` pair: XcodeGen groups embedded dependencies into
  one `PBXCopyFilesBuildPhase` per unique pair, and giving the agent and the
  CLI *different* pairs produced two build phases that both serialize under
  the name "Embed Dependencies" — CI caught these coming out in a different
  order than a local `xcodegen generate`, failing the "generated project is
  up to date" check non-deterministically. Both `SKIP_INSTALL: YES` so they
  aren't also installed standalone into archives.
- **(tested)** end-to-end: built the real app with this setup, ad-hoc-called
  `SMAppService.agent(plistName:).register()` from inside it (via a temporary
  hook, reverted before the commits on this branch), and confirmed
  `notFound → enabled` with **no System Settings approval step required**,
  then `unregister()` cleanly returned it to `notRegistered` with no residue
  in `launchctl`. Re-ran this after moving the agent to `Contents/Helpers`
  to confirm the path change didn't break registration. The embedding
  mechanics in `project.yml` work.

## Consequences

- The helper is a single point of failure/trust for the vault key, which is
  the intended design (smallest possible attack surface), but means its own
  process integrity (no one can inject code into it, e.g. via unsigned
  plugins) matters a lot once we're past the local dev-signing stage.
- Because we're deliberately not using `keychain-access-groups` or app groups,
  none of this design depends on the org's Apple Developer Program membership
  existing. [851-2400](https://linear.app/851/issue/851-2400) can ship local
  dev-signing today and defer only the *production* Developer ID team, which
  this ADR's decisions don't block on.
- If a later milestone wants iCloud Keychain-style sync of the vault key
  itself (explicitly out of scope — MVP decision is no iCloud, no sync of the
  key), that would mean adopting the DP keychain and revisiting this ADR.
