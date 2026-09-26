# Using `lilpass` from an agent

`lilpass` is a local, `op`-CLI-flavored way for a coding agent (Claude Code, Codex, Cursor, or
anything else that can shell out or speak MCP) to reach the passwords in your vault, without ever
touching the vault database or the Keychain item directly. Every command talks to
`LilPasswordsAgent` over XPC — see [`docs/adr/0001-storage-and-process-model.md`](adr/0001-storage-and-process-model.md)
for why that boundary exists.

Read this if you're setting `lilpass` up for an agent to use, or if you're an agent that's just been
told a `lilpass://` reference and needs to know what to do with it.

## 1. Turn on agent access

Two things both have to be true before `lilpass`/`lilpass mcp` can do anything:

1. **The vault is unlocked.** Same as unlocking in the app itself — `lilpass` never prompts for
   biometrics/password on its own; it just asks the already-unlocked helper.
2. **"Allow agents to access passwords" is turned on**, in the app's Settings → Agents.

With agent access on and the vault unlocked, `lilpass` and `lilpass mcp` behave exactly like any other
local process that can run them — see [`SECURITY.md`](../SECURITY.md) for the threat model this
implies before you turn it on.

Settings → Agents also has two settings that narrow what "agent access" means, both off/unscoped by
default:

- **"Allow agents to create, edit, and delete passwords"** — a separate toggle from read access
  (and disabled until read access is on). Off by default: without it, `lilpass add`/`edit`/`rm` and
  the MCP write tools all fail with exit code `8`, no matter what read access allows. See
  [§4](#4-creating-editing-and-deleting-passwords-write-access) below.
- **Access scope** — "All Passwords" (the default once agent access is on), "Only Selected
  Passwords" (an allowlist you build from the item list's context menu, individually or by group),
  or "Ask Every Time" (a Touch ID prompt for every request). See
  [§7](#7-scoped-access-and-touch-id-approval) below.

Check the current state any time with:

```sh
lilpass status
# locked: false
# agentAccessEnabled: true
```

or `lilpass status --json` for a script/agent-friendly `{"locked":false,"agentAccessEnabled":true}`.

## 2. Install `lilpass`

The easiest way: Settings → Agents → **Command Line Tool** → **Install "lilpass" Command**. This is
a one-click, no-admin-prompt install — it symlinks the CLI to `/usr/local/bin` if it can write
there, or falls back to `~/.local/bin` (in which case, make sure `~/.local/bin` is on your shell's
`PATH`). The same pane shows where it's currently installed, or flags it if something else is
already at that path.

Doing it by hand works too — `lilpass` ships inside the app bundle, at:

```
/Applications/lil passwords.app/Contents/Helpers/lilpass
```

```sh
ln -s "/Applications/lil passwords.app/Contents/Helpers/lilpass" /usr/local/bin/lilpass
```

Building from source (contributors, or before the app ships a signed release) is covered in the
top-level [`README.md`](../README.md#building); the resulting binary is at
`build/Build/Products/Debug/lil passwords.app/Contents/Helpers/lilpass`.

## 3. The pattern every agent should follow: never print secrets

`lilpass` has three commands that intentionally print a secret value to stdout — `get` (without
`--field`, or with `--field password`/`--field totp`/etc.), `read`, and `totp`. Everything else
(`list`, `search`, `status`, and the write commands below) is designed so a secret can never appear
in their output, even by accident — `add`/`edit` never echo back the password you just set.

If you're an agent whose own transcript might get logged, pasted, or read back by a human later,
**prefer the commands that resolve a secret without ever surfacing it to you or your own output**:

- **`lilpass run`** — resolves one or more `lilpass://item/field` references directly into a child
  process's environment, and never touches your context at all:

  ```sh
  lilpass run --env GITHUB_TOKEN=lilpass://github.com/password -- gh api user
  lilpass run --env DB_PASSWORD=lilpass://prod-db/password --env DB_USER=lilpass://prod-db/username -- psql
  ```

  `--env` may be repeated. `lilpass`'s own exit code is always the child's exact exit code (never
  one of `lilpass`'s own codes below) — see `lilpass run --help`.

- **`lilpass inject`** — the same idea for a file instead of a single child process: fills in every
  `{{ lilpass://item/field }}` placeholder in a template and writes the result to a separate output
  file (e.g. turning a `.env.example` into a real `.env`), atomically — if any placeholder fails to
  resolve, nothing is written at all, rather than leaving a partially-filled-in file with some
  secrets and some literal `lilpass://...` placeholders in it:

  ```sh
  lilpass inject -i .env.example -o .env
  ```

- **`lilpass add --password -` / `lilpass edit <item> --password -`** — when setting a password
  (rather than reading one), the same rule applies in reverse: never pass the secret as a literal
  command-line argument (it would land in shell history and process listings). Both commands
  require `--password` to be the literal string `-`, which reads the secret from stdin instead:

  ```sh
  echo -n hunter2 | lilpass add --title GitHub --username octocat --password -
  ```

  Or skip the secret entirely and have `lilpass` generate one — see
  [§4](#4-creating-editing-and-deleting-passwords-write-access).

Reach for `read` (`lilpass read lilpass://item/field`) or `get`/`totp` only when a human explicitly
needs to see the value, or when you genuinely need the secret in your own working context (e.g.
composing an API call body yourself rather than handing it to a subprocess) — and be aware that,
unlike `run`/`inject`, whatever you do with that value afterward is on you: if your own output gets
logged, so does the secret.

`docs/examples/skills/lilpass/SKILL.md` (below) packages exactly this guidance as a Claude Code
skill, so an agent picks the right command without needing this whole doc in context every time.

## 4. Creating, editing, and deleting passwords (write access)

`lilpass add`, `lilpass edit`, and `lilpass rm` let an agent manage vault items directly — not just
read them. All three require **both** agent access and the separate write-access toggle (Settings →
Agents → "Allow agents to create, edit, and delete passwords"); without write access, they fail with
exit code `8` regardless of what read access allows.

**`lilpass add`** — creates a new item:

```sh
echo -n hunter2 | lilpass add --title GitHub --username octocat --password - \
  --website github.com --notes "personal account"

lilpass add --title "New Service" --username octocat --generate --length 20
```

- `--title` is required.
- `--username` and `--website` may each be repeated for multiple values.
- Exactly one of `--password -` (reads the secret from stdin) or `--generate` (optionally paired
  with `--length`/`--no-symbols`) — a literal, non-`-` password value is rejected.
- `--notes` and `--group` are optional.

**`lilpass edit <item>`** — updates an existing item (same argument, same field flags as `add`).
`<item>` is resolved the same way as everywhere else (id, exact title, or an associated domain).
Important: **`--username`/`--website` replace that field's whole list when given at all** — they
don't merge with what's already there — so re-send every username/website you want to keep, not
just the new one.

```sh
lilpass edit GitHub --notes "rotated after the incident"
echo -n newpassword | lilpass edit GitHub --password -
```

**`lilpass rm <item>`** — removes an item. This is a soft delete: the item moves to the app's
Recently Deleted view, the same as deleting it from the app itself. There is no permanent-delete
request an agent can reach.

```sh
lilpass rm "Old Service"
```

The MCP equivalents are `create_password`, `update_password`, and `delete_password` — see
[§8](#8-mcp-setup--connect-agents).

## 5. `lilpass://item/field` references

Modeled directly on 1Password CLI's `op://vault/item/field`:

```
lilpass://<item>/<field>
```

- `<item>` is an item's id, its exact title (case-insensitive), or a website domain it's associated
  with — the same three things `lilpass get`/`lilpass totp`'s bare argument accepts. This only ever
  resolves to a regular vault item — Wi-Fi network passwords aren't part of the vault's item model
  at all and have no `lilpass://` form; see [`SECURITY.md`](../SECURITY.md) for why they're excluded
  from every agent-reachable surface entirely.
- `<field>` is one of `password`, `username`, `totp`, `notes`, `website`.

```sh
lilpass read lilpass://github.com/password
lilpass run --env NPM_TOKEN=lilpass://npmjs.com/password -- npm publish
```

If `<item>` matches more than one item, or matches none, the command fails with exit code 6
(`ambiguous`) or 5 (`notFound`) respectively — see below.

## 6. Exit codes

Every `lilpass` command uses the same stable, documented exit codes, so a script or agent can branch
on the exit code alone instead of parsing stderr text:

| Code | Meaning |
| --- | --- |
| `0` | ok |
| `1` | generic failure |
| `2` | usage error (bad arguments, malformed `lilpass://` reference, unreadable input file) |
| `3` | vault is locked |
| `4` | agent access is turned off in Settings |
| `5` | item not found |
| `6` | item reference is ambiguous (matches more than one item) |
| `7` | couldn't reach `LilPasswordsAgent` at all |
| `8` | write access is turned off in Settings (`add`/`edit`/`rm` only) |
| `9` | a Touch ID approval was denied or timed out (`accessScope` = "Ask Every Time" only) |

`lilpass run` is the one exception: its exit code is always the child process's own exit code, never
one of the codes above — see `lilpass run --help`.

Every non-zero exit also prints a one-line, human-readable (and secret-free) message to stderr, and
every command supports `--json` for a structured result instead of the plain-text one shown above.

## 7. Scoped access and Touch ID approval

Settings → Agents' access-scope picker controls *which* items agent access applies to, independent
of the read/write toggles above:

- **All Passwords** (the default) — every item in the vault is reachable, exactly as described
  everywhere else in this doc.
- **Only Selected Passwords** — agents can only reach items you've allowed individually (from the
  item list's context menu) or by group. Anything not on that allowlist behaves as if it doesn't
  exist: `lilpass`/`lilpass mcp` fail with exit code `5` (`notFound`), never `6` (`ambiguous`) — a
  scoped-out item is designed to be indistinguishable from a nonexistent one, so an agent can't use
  the difference to enumerate what's in your vault.
- **Ask Every Time** — every request (other than generating a fresh password, which needs nothing
  from the vault) pauses for a Touch ID approval prompt in the app, showing what's being requested
  and by which process. You choose **Allow Once**, **Allow for 15 Minutes**, or **Deny**. A denied
  or unanswered request (after roughly a minute) fails with exit code `9`
  (`approvalDeniedOrTimedOut`) — so scripting against "Ask Every Time" only makes sense if a human
  is actually there to approve it.

See [`docs/adr/0007-scoped-agent-access.md`](adr/0007-scoped-agent-access.md) for the full design,
including how the 15-minute grant is tied to the requesting agent's own process rather than a raw
pid (so it survives short-lived child processes without also surviving a restart of the agent
itself).

## 8. MCP setup / Connect Agents

`lilpass mcp` runs `lilpass` itself as a stdio MCP server, exposing eight tools — the same read/write
split as the CLI:

| Tool | Reveals a secret? | Notes |
| --- | --- | --- |
| `list_passwords` | No | optional `category` filter |
| `search_passwords` | No | `query` |
| `get_password` | Yes | `item` |
| `get_verification_code` | Yes | `item` (TOTP) |
| `generate_password` | No | `length`, `noSymbols` |
| `create_password` | No | requires write access; `title` required, same optional fields as `lilpass add` |
| `update_password` | No | requires write access; `item` required, same optional fields as `lilpass edit` |
| `delete_password` | No | requires write access; `item` (soft-delete only, same as `lilpass rm`) |

Point any MCP-capable client at `lilpass mcp` (not a network endpoint — it's stdio only, one process
per client session, same access-control rules as every other `lilpass` command, including the
write-access toggle and access scope above).

The easiest way to wire a client up: Settings → Agents → **Connect Agents**, which lists Claude
Code, Codex, and Cursor, each with **Copy Setup** and **Add Automatically** buttons. Both use the
*absolute path* to whichever `lilpass` is actually installed (the one-click-installed symlink if
present, otherwise the path inside the app bundle) — so the config it writes keeps working even if
`lilpass` isn't on that particular tool's `PATH`.

Doing it by hand works the same way:

**Claude Code:**

```sh
claude mcp add lilpass -- lilpass mcp
```

or, if `lilpass` isn't on `PATH`, the full path to the binary:

```sh
claude mcp add lilpass -- "/Applications/lil passwords.app/Contents/Helpers/lilpass" mcp
```

**Codex** (`~/.codex/config.toml`):

```toml
[mcp_servers.lilpass]
command = "lilpass"
args = ["mcp"]
```

**Cursor** (`.cursor/mcp.json` in a project, or Cursor's global MCP settings):

```json
{
  "mcpServers": {
    "lilpass": {
      "command": "lilpass",
      "args": ["mcp"]
    }
  }
}
```

A locked vault, disabled agent/write access, a scoped-out item, or a denied approval all surface as
a normal MCP tool error (`isError: true`) with the same message `lilpass`'s CLI commands would print
to stderr for the same condition — there's no separate MCP-specific error format to learn.

## See also

- [`docs/examples/skills/lilpass/SKILL.md`](examples/skills/lilpass/SKILL.md) — a ready-to-drop-in
  Claude Code skill that teaches an agent this doc's "never print secrets" guidance directly.
- [`docs/examples/AGENTS.md.snippet.md`](examples/AGENTS.md.snippet.md) — a short section to paste
  into a project's own `AGENTS.md`/`CLAUDE.md` pointing any agent working in that repo at `lilpass`.
- [`SECURITY.md`](../SECURITY.md) — the threat model behind "agent access" as a concept: what it
  protects against, what it doesn't, and how to report a vulnerability.
- [`docs/adr/0001-storage-and-process-model.md`](adr/0001-storage-and-process-model.md) — why
  `lilpass` talks to a helper over XPC instead of touching the vault directly.
- [`docs/adr/0007-scoped-agent-access.md`](adr/0007-scoped-agent-access.md) — the design behind
  §7's access scopes and Touch ID approval flow.
