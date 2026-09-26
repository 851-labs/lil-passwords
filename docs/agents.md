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

Check the current state any time with:

```sh
lilpass status
# locked: false
# agentAccessEnabled: true
```

or `lilpass status --json` for a script/agent-friendly `{"locked":false,"agentAccessEnabled":true}`.

## 2. Install `lilpass`

`lilpass` ships inside the app bundle, at:

```
/Applications/lil passwords.app/Contents/Helpers/lilpass
```

Put it on your `PATH` (a symlink is fine and won't go stale across in-place app updates only if
you re-link after a version bump that changes the bundle's internal layout — a plain copy is
simpler to reason about if you'd rather not think about that):

```sh
ln -s "/Applications/lil passwords.app/Contents/Helpers/lilpass" /usr/local/bin/lilpass
```

Building from source (contributors, or before the app ships a signed release) is covered in the
top-level [`README.md`](../README.md#building); the resulting binary is at
`build/Build/Products/Debug/lil passwords.app/Contents/Helpers/lilpass`.

## 3. The pattern every agent should follow: never print secrets

`lilpass` has three commands that intentionally print a secret value to stdout — `get` (without
`--field`, or with `--field password`/`--field totp`/etc.), `read`, and `totp`. Everything else
(`list`, `search`, `status`) is designed so a secret can never appear in their output, even by
accident.

If you're an agent whose own transcript might get logged, pasted, or read back by a human later,
**prefer the commands that resolve a secret without ever surfacing it to you or your own output**:

- **`lilpass run`** — resolves one or more `lilpass://item/field` references directly into a child
  process's environment, and never touches your context at all:

  ```sh
  lilpass run --env GITHUB_TOKEN=lilpass://github.com/password -- gh api user
  lilpass run --env DB_PASSWORD=lilpass://prod-db/password --env DB_USER=lilpass://prod-db/username -- psql
  ```

  `--env` may be repeated. `lilpass`'s own exit code is always the child's exact exit code (never
  one of `lilpass`'s own 0–7 codes below) — see `lilpass run --help`.

- **`lilpass inject`** — the same idea for a file instead of a single child process: fills in every
  `{{ lilpass://item/field }}` placeholder in a template and writes the result to a separate output
  file (e.g. turning a `.env.example` into a real `.env`), atomically — if any placeholder fails to
  resolve, nothing is written at all, rather than leaving a partially-filled-in file with some
  secrets and some literal `lilpass://...` placeholders in it:

  ```sh
  lilpass inject -i .env.example -o .env
  ```

Reach for `read` (`lilpass read lilpass://item/field`) or `get`/`totp` only when a human explicitly
needs to see the value, or when you genuinely need the secret in your own working context (e.g.
composing an API call body yourself rather than handing it to a subprocess) — and be aware that,
unlike `run`/`inject`, whatever you do with that value afterward is on you: if your own output gets
logged, so does the secret.

`docs/examples/skills/lilpass/SKILL.md` (below) packages exactly this guidance as a Claude Code
skill, so an agent picks the right command without needing this whole doc in context every time.

## 4. `lilpass://item/field` references

Modeled directly on 1Password CLI's `op://vault/item/field`:

```
lilpass://<item>/<field>
```

- `<item>` is an item's id, its exact title (case-insensitive), or a website domain it's associated
  with — the same three things `lilpass get`/`lilpass totp`'s bare argument accepts.
- `<field>` is one of `password`, `username`, `totp`, `notes`, `website`.

```sh
lilpass read lilpass://github.com/password
lilpass run --env NPM_TOKEN=lilpass://npmjs.com/password -- npm publish
```

If `<item>` matches more than one item, or matches none, the command fails with exit code 6
(`ambiguous`) or 5 (`notFound`) respectively — see below.

## 5. Exit codes

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

`lilpass run` is the one exception: its exit code is always the child process's own exit code, never
one of the codes above — see `lilpass run --help`.

Every non-zero exit also prints a one-line, human-readable (and secret-free) message to stderr, and
every command supports `--json` for a structured result instead of the plain-text one shown above.

## 6. MCP setup

`lilpass mcp` runs `lilpass` itself as a stdio MCP server, exposing five read-only tools:
`list_passwords`, `search_passwords`, `get_password`, `get_verification_code`, and
`generate_password`. Point any MCP-capable client at `lilpass mcp` (not a network endpoint — it's
stdio only, one process per client session, same access-control rules as every other `lilpass`
command).

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

A locked vault or disabled agent access surfaces as a normal MCP tool error (`isError: true`) with
the same message `lilpass`'s CLI commands would print to stderr for the same condition — there's no
separate MCP-specific error format to learn.

## See also

- [`docs/examples/skills/lilpass/SKILL.md`](examples/skills/lilpass/SKILL.md) — a ready-to-drop-in
  Claude Code skill that teaches an agent this doc's "never print secrets" guidance directly.
- [`docs/examples/AGENTS.md.snippet.md`](examples/AGENTS.md.snippet.md) — a short section to paste
  into a project's own `AGENTS.md`/`CLAUDE.md` pointing any agent working in that repo at `lilpass`.
- [`SECURITY.md`](../SECURITY.md) — the threat model behind "agent access" as a concept: what it
  protects against, what it doesn't, and how to report a vulnerability.
- [`docs/adr/0001-storage-and-process-model.md`](adr/0001-storage-and-process-model.md) — why
  `lilpass` talks to a helper over XPC instead of touching the vault directly.
