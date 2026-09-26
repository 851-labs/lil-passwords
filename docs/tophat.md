# Tophatting `lilpw` and `lilpw mcp` locally

`LilPasswordsAgent` only serves vault requests when both of these are true:

1. The vault is unlocked (someone authenticated via the app's `LAContext` flow and handed the
   helper a session key).
2. "Allow agents to access passwords" is turned on in Settings → Agents.

(2) is the 851-2428 Settings toggle. Until it exists, the helper hardcodes
`AlwaysDenyAccessPolicy` (see `Agent/Sources/main.swift`), so a real, launchd-managed helper always
refuses `lilpw`/`lilpw mcp` — there's no UI yet to turn it on.

To unblock tophatting 851-2430/851-2431 against the real helper before 851-2428 lands,
`Agent/Sources/main.swift` has a **DEBUG-only** override. It does not exist in a Release build —
the entire check is inside `#if DEBUG`, and the `#else` branch is an unconditional
`AlwaysDenyAccessPolicy()` with no override path at all — so there is no way for this to ship
enabled, or at all, in a Release/archived build.

## Enabling it

Pick one:

- **Env var**, for a helper launchd activates on demand (the normal path — see
  `docs/adr/0001-storage-and-process-model.md`):

  ```sh
  launchctl setenv LILPW_TOPHAT_ALLOW_AGENT_ACCESS 1
  ```

  launchd only reads its managed environment when it *activates* the on-demand service, so if
  `LilPasswordsAgent` is already running, kill it first so the next connection attempt relaunches
  it with the new environment:

  ```sh
  launchctl kill SIGTERM gui/$(id -u)/com.851labs.lilpasswords.agent
  ```

  Unset it when you're done so a normal (non-DEBUG) rebuild of the app/helper doesn't leave
  anything surprising set in your shell/session:

  ```sh
  launchctl unsetenv LILPW_TOPHAT_ALLOW_AGENT_ACCESS
  ```

- **Launch argument**, if you're running the helper binary directly (e.g. from Xcode, or
  `build/Build/Products/Debug/LilPasswordsAgent.app/Contents/MacOS/LilPasswordsAgent` in a
  terminal) rather than through launchd:

  ```sh
  LilPasswordsAgent --allow-agent-access-debug
  ```

Either way, you still need the vault *unlocked* — the override only flips the Settings toggle's
stand-in, not the lock state. Unlock via the app's normal flow (or, in a unit/integration test, via
`AgentClient.unlock(sessionKey:keyId:)` directly, which is how `LilpwCoreTests`' `Harness` does it
without any of this).

## Running `lilpw` against the real helper

```sh
make project && make build
"build/Build/Products/Debug/Lil Passwords.app/Contents/Helpers/lilpw" status
"build/Build/Products/Debug/Lil Passwords.app/Contents/Helpers/lilpw" list --json
```

**Caveat as of 851-2430/851-2431**: `AppDelegate` doesn't call
`SMAppService.agent(plistName:).register()` anywhere yet — the ADR's "Infrastructure landed
alongside this spike" section describes this as tested via a temporary, reverted hook, not as
wired into app startup. Until some ticket adds that call, launchd never learns about
`com.851labs.lilpasswords.agent.xpc` at all, so *every* `lilpw` command that needs the helper
(`status`, `list`, `search`, `get`, `read`, `totp`, `generate`, and `run`/`inject` when they
actually need to resolve a `lilpw://` reference) fails with exit code 7
("the connection to LilPasswordsAgent was invalidated") regardless of the DEBUG override above —
this is a real, currently-true gap, not specific to this branch, and not something 851-2430/851-2431
should fix (it's a separate concern from either ticket's scope).

What that leaves as real, meaningful verification without a registered helper:

- `LilpwCoreTests` (`swift test --package-path Packages/LilPasswordsKit`) drives every `LilpwCore`
  entry point over a **real XPC round trip** — `AgentClient` talking to a real `AgentServer`
  through a real `NSXPCConnection`/`NSXPCListener` pair — just an anonymous one instead of a
  Mach-service one, via `Harness`. This is the primary correctness signal for 851-2430's actual
  logic (resolution, exit codes, `--json`, `run`'s env injection, `inject`'s atomicity).
- Everything in `lilpw` that doesn't need the helper still runs for real against the built binary:
  argument parsing and validation (`--help` for every subcommand, unknown `--field` values,
  malformed `lilpw://` references, `run` with no command after `--`), and — notably — `lilpw run`
  itself is fully real end-to-end when it has no `--env` to resolve (e.g. `lilpw run -- true`
  actually execs `/usr/bin/env true` and forwards its exit code, with zero mocking).

See `~/lil-passwords-tophat/851-2430/01-cli-transcript.txt` for a captured session covering both
categories.

## Running `lilpw mcp` from Claude Code

```sh
cd /tmp/some-scratch-dir
claude mcp add lilpw -- /path/to/lilpw mcp
claude -p "List my saved passwords"
```

Save the transcript (and any relevant screenshots) under
`~/lil-passwords-tophat/<ticket>/` when tophatting a PR.
