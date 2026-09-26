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

**Caveat as of 851-2430/851-2431**: `AppDelegate` doesn't call
`SMAppService.agent(plistName:).register()` anywhere yet — the ADR's "Infrastructure landed
alongside this spike" section describes this as tested via a temporary, reverted hook, not as
wired into app startup. Until some ticket adds that call, launchd never learns about
`com.851labs.lilpasswords.agent.xpc` at all, so *every* `lilpass` command that needs the helper
(`status`, `list`, `search`, `get`, `read`, `totp`, `generate`, and `run`/`inject` when they
actually need to resolve a `lilpass://` reference) fails with exit code 7
("the connection to LilPasswordsAgent was invalidated") regardless of the Settings → Agents toggle
above — this is a real, currently-true gap, not specific to this branch, and not something
851-2430/851-2431 (or 851-2428/851-2429/851-2460) should fix; it's a separate, pre-existing concern
outside all of their scopes.

What that leaves as real, meaningful verification without a registered helper:

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

## Running `lilpass mcp` from Claude Code

```sh
cd /tmp/some-scratch-dir
claude mcp add lilpass -- /path/to/lilpass mcp
claude -p "List my saved passwords"
```

Save the transcript (and any relevant screenshots) under
`~/lil-passwords-tophat/<ticket>/` when tophatting a PR.
