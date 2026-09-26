# Security

This is a plain-language threat model for lil passwords, not a compliance document. If you're
deciding whether to turn on agent access, or whether lil passwords is safe to use on a given Mac,
read this first.

## The headline claim

**With agent access turned on and the vault unlocked, any local process that can run `lilpass` can
read every password, username, note, and TOTP secret in your vault.**

That's not a bug to be tightened later — it's what "agent access" means. `lilpass` is a bare
command-line tool with no sandbox and no per-item permission prompt: it asks `LilPasswordsAgent`
for whatever it wants, and the helper hands it over, the same way it would for the app itself. A
coding agent, a shell script, a malicious `npm` postinstall hook, another user-level process — none
of these are distinguishable from "you, using `lilpass` on purpose" once both conditions above are
true. See [`docs/adr/0001-storage-and-process-model.md`](docs/adr/0001-storage-and-process-model.md)
for why the architecture is shaped this way (one process holds the key; everything else asks it
over XPC) — that design makes the vault key hard to exfiltrate from the app or from `lilpass`
directly, but it doesn't and can't restrict who's allowed to *ask*.

## What each control actually does

- **The "Allow agents to access passwords" toggle** (Settings → Agents) is the only thing standing
  between "any local process can read the vault via `lilpass`" and "no process can, no matter what
  it tries." Off is the default, and off is a hard stop: `LilPasswordsAgent` refuses every
  `lilpass`/`lilpass mcp` request with exit code 4, regardless of lock state. It does **not**
  distinguish one local process from another — it's a single global switch, not a per-agent or
  per-app allowlist.
- **The vault lock** protects the vault when you're not actively using it, the same as it would
  against a person sitting down at an unattended, logged-in Mac. It does **not** protect anything
  while the vault is unlocked, which is the state agent access is designed to be used in — locking
  and agent access are two independent gates, and both currently have to be open for `lilpass` to
  return a secret.
- **The access log** (Settings → Agents) makes agent access visible after the fact — every
  `lilpass`/`lilpass mcp` request is recorded, so you can notice a request you didn't expect. It's a
  detection control, not a prevention control: it doesn't block anything, and if the Mac itself is
  compromised, an attacker capable enough to read the vault this way is also capable of clearing or
  ignoring the log.
- **The code-signing requirement** on the XPC connection between `lilpass`/the app and
  `LilPasswordsAgent` (see
  [`AgentConnectionSecurity`](Packages/LilPasswordsKit/Sources/LilPasswordsKit/Agent/AgentConnectionSecurity.swift))
  stops a *different, unrelated app* from impersonating `lilpass` or squatting the helper's Mach
  service name to intercept a connection. It does **not** stop the real, genuine `lilpass` binary
  from being run by anything — that's the whole point of `lilpass` existing. On an unsigned/ad-hoc
  local build (the default until a Developer ID team is configured — see
  [`docs/releasing.md`](docs/releasing.md)), this requirement isn't enforced at all
  (`.developmentFallback`); it only starts doing real work once the app is built with a real team
  identity.

## Two scenarios worth being explicit about

**Your Mac is stolen, locked/off.** The vault itself is encrypted at rest (see
[`docs/adr/0002-crypto.md`](docs/adr/0002-crypto.md)); reading it requires deriving the vault key,
which requires your unlock secret (password or recovery key) or a working Touch ID against your
enrolled biometrics. A thief who can't log into the Mac at all gets nothing from lil passwords
specifically that they didn't already get from being locked out of the whole machine.

**Your Mac is stolen, unlocked and logged in — or has malware running as you.** This is the
scenario agent access exists for, running in reverse. Anything that can execute code as you can run
`lilpass` exactly like an agent would. If the vault happens to be unlocked and agent access happens
to be on at that moment, the vault is fully readable, no further prompt required. This isn't unique
to lil passwords — it's true of any password manager's unlocked state, and of your browser's saved
passwords, and of anything else that trusts "is this process running as the logged-in user" as its
security boundary — but it's worth saying plainly rather than implying agent access is somehow
sandboxed against it. **If you're not actively using agent access, turn it off.** It defaults to
off for exactly this reason.

## The recovery key

Shown once, when you set one up (see
[`VaultCrypto+RecoveryKey`](Packages/LilPasswordsKit/Sources/LilPasswordsKit/VaultCrypto/VaultCrypto%2BRecoveryKey.swift)),
the recovery key is an independent way to derive the vault key if you ever lose your password —
not a backup copy of your data stored anywhere else, and not synced or uploaded. Treat it like a
second master password: anyone who has it can unlock the vault exactly as if they knew your
password, and lil passwords has no way to reset or recover it if you lose both. Store it somewhere
offline and separate from the Mac it protects (a physical safe, a different password manager
entirely) — not in a file on the same disk.

## What this is not

- Not sandboxed: `lilpass` is a plain Mach-O, not sandboxed and holding no special entitlement to the
  vault or Keychain — see [`docs/adr/0001-storage-and-process-model.md`](docs/adr/0001-storage-and-process-model.md)
  for why (the entitlement to talk to `LilPasswordsAgent` lives on the helper's XPC listener, not on
  `lilpass`).
- Not a defense against a compromised `LilPasswordsAgent` or `lil passwords.app` binary itself, or
  against root/kernel-level compromise of the Mac. The threat model here is "another local,
  non-privileged process," not "the OS or this app's own binaries have been tampered with."
- Not a network service: there is no remote attack surface — everything above is about what a
  *local* process can do.

## Reporting a vulnerability

Please report security issues privately via
[GitHub Security Advisories](https://github.com/851-labs/lil-passwords/security/advisories/new)
for this repository, rather than filing a public issue. Include what you found, how to reproduce
it, and its impact as you understand it; we'll follow up from there.
