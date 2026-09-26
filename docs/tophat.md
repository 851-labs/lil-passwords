# Tophatting `lilpass` and `lilpass mcp` locally

`LilPasswordsAgent` only serves vault requests when both of these are true:

1. The vault is unlocked (someone authenticated via the app's `LAContext` flow and handed the
   helper a session key).
2. "Allow agents to access passwords" is turned on in Settings → Agents.

(2) is the real, 851-2428 Settings → Agents toggle: `AgentSettingsAccessPolicy` (see
`Agent/Sources/main.swift`) reads it live from a helper-owned Keychain item — never
`UserDefaults` — via the gated `getAgentSettings`/`setAgentSettings` XPC ops (see
`docs/adr/0001-storage-and-process-model.md` (e)). There's no DEBUG-only override for this
anymore: the toggle is real, so tophatting `lilpass`/`lilpass mcp` against a launchd-managed
helper just means turning it on in the app's own Settings window, the same way an end user would.

## Enabling it

1. Launch the app and open Settings → Agents.
2. Turn on "Allow agents to access passwords".
3. Unlock the vault via the app's normal flow (Touch ID/password) — the toggle alone isn't
   enough; `AgentSettingsAccessPolicy.isAccessAllowed(for:)` still requires the vault to be
   unlocked for any non-app caller (`lilpass`, the MCP server). In a unit/integration test, unlock
   instead via `AgentClient.unlock(sessionKey:keyId:)` directly, which is how `LilpassCoreTests`'
   `Harness` does it.

## Running `lilpass` against the real helper

```sh
make project && make build
"build/Build/Products/Debug/lil passwords.app/Contents/Helpers/lilpass" status
"build/Build/Products/Debug/lil passwords.app/Contents/Helpers/lilpass" list --json
```

**Update (851-2411, then re-verified end-to-end by 851-2465)**: `AppDelegate.applicationDidFinishLaunching`
now calls `HelperAgentRegistrar.registerIfNeeded(using:)` (a thin wrapper around
`SMAppService.agent(plistName:).register()`) on every launch, before anything else touches the
helper — so the caveat that used to live in this section (every `lilpass` command failing with
exit code 7 because launchd never learned about `com.851labs.lilpasswords.agent.xpc`) no longer
applies. Launching the app — from Xcode, `open build/Build/Products/Debug/lil\ passwords.app`, or a
real `/Applications` install — is now enough to get `LilPasswordsAgent` registered with launchd.
Two things can still stand between you and a reachable helper:

If you still see `lilpass` fail with exit code 7 in this shared, multi-worktree dev environment
despite the helper being registered and approved, it's most likely the shared-machine hazard
documented further down this file (every concurrent build/worktree on this machine shares the same
`com.851labs.lilpasswords.agent.xpc` registration and vault file) rather than a registration bug.
For tophatting without waiting on a real registered helper to settle, the app has its own
documented escape hatch: `LILPASSWORDS_OFFLINE_DEMO=1 LILPASSWORDS_FAKE_AUTH=1` (see
`App/Sources/OfflineDemoAgent.swift` and `MainWindowController.makeAgent`/`makeAuthenticator`) swaps
in an in-process fake agent and authenticator instead of the real XPC connection, so Settings/lock
screen captures aren't blocked on launchd cooperating. Setting only `LILPASSWORDS_FAKE_AUTH=1`
(leaving `LILPASSWORDS_OFFLINE_DEMO` unset) is also useful on its own: it bypasses just the local
`LAContext` Touch ID/password prompt while still exercising the real signed helper's actual
`unlock()` over XPC — used during 851-2465's smoke test to unlock a real install without a Touch ID
sensor or this machine's account password available.

- **First registration on this Mac needs a Login Items approval.** The very first time
  `LilPasswordsAgent` registers on a given Mac, `SMAppService` reports `.requiresApproval` rather
  than `.enabled` — launchd knows about the service but won't actually run it until a human
  approves it in System Settings → General → Login Items & Extensions. The app shows a one-time
  sheet for this ("Allow lil passwords to Run in the Background") with an "Open System Settings"
  button; the 851-2465 lock screen also shows the same "Open Login Items…" action if you dismiss
  that sheet and then hit an unlock failure while still unapproved. Approve it once and every
  subsequent launch (including of a different build signed the same way) goes straight to
  `.enabled`.
- **An unsigned/ad-hoc DEBUG build can still fail the code-signing requirement.** See the next
  section.

What that leaves as real, meaningful verification once the helper is registered and approved:

- `LilpassCoreTests` (`swift test --package-path Packages/LilPasswordsKit`) drives every `LilpassCore`
  entry point over a **real XPC round trip** — `AgentClient` talking to a real `AgentServer`
  through a real `NSXPCConnection`/`NSXPCListener` pair — just an anonymous one instead of a
  Mach-service one, via `Harness`. This is the primary correctness signal for 851-2430's actual
  logic (resolution, exit codes, `--json`, `run`'s env injection, `inject`'s atomicity).
- Everything in `lilpass` that doesn't need the helper still runs for real against the built binary:
  argument parsing and validation (`--help` for every subcommand, unknown `--field` values,
  malformed `lilpass://` references, `run` with no command after `--`), and — notably — `lilpass run`
  itself is fully real end-to-end when it has no `--env` to resolve (e.g. `lilpass run -- true`
  actually execs `/usr/bin/env true` and forwards its exit code, with zero mocking).

See `~/lil-passwords-tophat/851-2430/01-cli-transcript.txt` for a captured session covering both
categories.

## Running the app against a real, launchd-managed helper (851-2465)

The default `make build` produces an **ad-hoc-signed** (`CODE_SIGN_IDENTITY = -`) Debug build.
That's fine for `LilpassCoreTests`' in-process XPC harness (there's no real team identifier to
check either side of an anonymous listener), but it's the wrong thing for exercising the *real*
Mach-service path end to end: `AgentConnectionSecurity.requirement(acceptingPeers:)` sees no team
identifier on an ad-hoc binary and falls back to `.developmentFallback` (DEBUG) or `.rejectAll`
(Release) rather than a real `anchor apple generic and certificate leaf[subject.OU] = "TEAMID"`
check — see that type's doc comment. `.developmentFallback` still lets same-machine testing work
(it accepts any peer), but it means the code-signing requirement itself isn't being tested, and a
`.rejectAll` (non-DEBUG, unsigned) build can't reach the helper at all — every request fails with
`AgentClient.RequestError.connection`, which is exactly the "helper unreachable" case 851-2465
adds friendly copy for (see below).

To exercise the real, signed path locally:

1. Create `Config/Local.xcconfig` (gitignored — never committed) with:

   ```
   CODE_SIGN_IDENTITY = Apple Development
   ```

   `Config/Base.xcconfig` already sets `DEVELOPMENT_TEAM` and `CODE_SIGN_STYLE = Manual`; this is
   the only override a local Apple Development identity needs. `security find-identity -v
   -p codesigning` lists what's available in your keychain if you're not sure you have one.
2. `make project && make build`.
3. Copy the resulting `build/Build/Products/Debug/lil passwords.app` to `/Applications/` (a
   `SMAppService` login item has to be launched from a stable, user-visible path — it won't
   register reliably from inside `build/`) and launch it from there.
4. `launchctl print gui/$UID/com.851labs.lilpasswords.agent` shows the registered service once the
   app has launched at least once; if it says the service needs approval, see the Login Items note
   above.
5. `"/Applications/lil passwords.app/Contents/Helpers/lilpass" status` now talks to the real,
   signed, launchd-managed helper — a real `anchor apple generic and certificate leaf[subject.OU] =
   "TEAMID"` check on both sides of the connection, not the DEBUG fallback.

**Only one `/Applications/lil passwords.app` should exist on a shared dev machine at a time** —
back up (and, when you're done, restore) `~/Library/Application Support/lil passwords/` and the
`com.851labs.lilpasswords.vaultkey` Keychain item first if either already exists, since a real
install touches both, and restore them (and remove the installed app) once you're done. **Unregister
via the app's own `SMAppService.agent(plistName:).unregister()` call (e.g. quit the app, or use a
small throwaway probe binary that calls it), never `launchctl bootout`.** `bootout` operates
directly on launchd's domain and does not go through `smd`'s bookkeeping at all — it desyncs
`SMAppService`'s cached status (which can keep reporting `.enabled`) from launchd's actual domain
state (which then has no record of the service), and the next `register()` call has to untangle
that mismatch. Confirmed empirically during 851-2465: after a `bootout`, `SMAppService.status`
still reported `.enabled` while `launchctl print` said "Could not find service"; a proper
`unregister()` resolved both sides back to `.notRegistered` cleanly.

**Warning: the vault store and the agent registration are both single, machine-wide-per-user
resources, not scoped per build or worktree.** `VaultStore.defaultDatabaseURL()` always resolves to
`~/Library/Application Support/lil passwords/vault.sqlite`, and the
`com.851labs.lilpasswords.agent.xpc` Mach service is one systemwide-per-user registration. On a
shared dev machine running multiple concurrent worktrees/builds of this app, **every one of them
talks to the same vault file and the same real agent process**, regardless of which one installed
it or where each build lives on disk. Confirmed during 851-2465: a freshly-created vault picked up
sample data seeded by a concurrently-running build in a different worktree, and a vault unlocked by
one instance was observed to re-lock moments later with no local action taken — almost certainly
another concurrent instance's own lock/relaunch acting on the same shared agent. Treat any
multi-agent tophat session on a shared machine as inherently racy for anything that touches vault
state or the agent's lock state; a single-instance-at-a-time discipline (announce before installing
to `/Applications`, as this doc already says) reduces but does not eliminate this.

### A deeper code-signing failure mode: the empty-cdhash LWCR bug

Fixing the codesign identifier mismatch above (`OTHER_CODE_SIGN_FLAGS -i ...` in `project.yml`, and
the matching `-i` flags in `scripts/release/sign.sh`) is necessary but was not sufficient for a real
signed install. With only that fix, `launchctl print gui/$UID/com.851labs.lilpasswords.agent` showed
the job permanently stuck `spawn scheduled` / `spawn failed`, `last exit reason =
OS_REASON_CODESIGNING`, and — the actual root cause — its LWCR (Lightweight Code Requirement, the
requirement `smd` computes and hands to the kernel to gate every spawn of this job) showing an
**empty allowed-cdhash set**: `"cdhash" => {"$in" => []}`. That's a requirement that matches no
signature at all, including a perfectly valid one, so every spawn attempt was killed by the kernel
before `main()` ever ran.

Root cause: `LilPasswordsAgent` and `lilpass` are both bare `com.apple.product-type.tool` Mach-O
binaries with **no embedded Info.plist whatsoever** (`codesign -dvv` showed `Info.plist=not bound`;
`GENERATE_INFOPLIST_FILE = YES` produces no `__TEXT,__info_plist` section at all for `tool`
targets — confirmed via `otool -s __TEXT __info_plist`). Without a real `CFBundleIdentifier`
anywhere in the binary, `smd` has nothing to key a valid LWCR from, and silently produces the
empty-cdhash version instead of erroring loudly.

Fix: link a minimal Info.plist directly into each tool's `__TEXT,__info_plist` section via
`OTHER_LDFLAGS: -Wl,-sectcreate,__TEXT,__info_plist,<path>` (see `project.yml`, `Agent/Support/Info.plist`,
`CLI/Support/Info.plist`) — the same technique Apple's own SMAppService/helper-tool sample code uses
for non-bundle executables. Confirmed via `otool -s __TEXT __info_plist` (real plist content now
present) and `codesign -dvv` (`Info.plist entries=5` instead of `not bound`); after a clean
unregister + reinstall + relaunch, `launchctl print` showed `state = running`, a real `pid`, and a
valid LWCR keyed off `signing-identifier = "com.851labs.lilpasswords.agent"` /
`team-identifier = "WH4QW9ND3J"` with no empty cdhash set.

This appears to recur intermittently after manually killing an already-running, correctly-registered
agent process directly (e.g. `kill <pid>`, done to force launchd to respawn it and pick up a new
`launchctl setenv`'d variable) rather than letting `SMAppService`/launchd manage its lifecycle
normally — a clean `unregister()` + relaunch cycle resolved it again each time this was observed,
sometimes needing more than one attempt. Prefer quitting the app (which triggers a normal
unregister/relaunch path) over signaling the agent process directly when you need it to pick up a
new environment variable.

### The friendly "helper unreachable" error, and its DEBUG-only hint

Every `AgentClient.RequestError.connection` case — the helper crashed, was killed, failed the
code-signing check, or never resolved at all — surfaces on the 851-2422 lock screen as exactly
**"Couldn't reach lil passwords' background helper."**, with a **Try Again** button in place of
**Use Password…** (see `UnlockFailure.describing(_:)` and `MainWindowController.failurePresentation(for:)`).
Two things can appear under that message:

- A **Login Items** hint + button, when `HelperAgentRegistering.status == .requiresApproval` — the
  same "needs to be turned on in Login Items" case described above.
- In **DEBUG, ad-hoc-signed** builds only (i.e. `AgentConnectionSecurity.requirement(acceptingPeers:)`
  reports `.developmentFallback`), a one-line hint pointing back at this file: *"Running an
  unsigned/ad-hoc DEBUG build? See docs/tophat.md to run against a real helper."* This never
  appears in a build signed with a real identity (the case this whole section walks through), and
  the `#if DEBUG` around it means it can never appear in a Release build regardless of signing.

## Running `lilpass mcp` from Claude Code

```sh
cd /tmp/some-scratch-dir
claude mcp add lilpass -- /path/to/lilpass mcp
claude -p "List my saved passwords"
```

Save the transcript (and any relevant screenshots) under
`~/lil-passwords-tophat/<ticket>/` when tophatting a PR.
