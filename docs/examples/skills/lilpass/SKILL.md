---
name: lilpass
description: Use lil passwords' lilpass CLI to reach a user's saved passwords/tokens/TOTP codes without ever printing the secret value into the conversation or a shell command's own output. Trigger whenever a task needs a credential lil passwords might already have — an API token, a database password, a login for a CLI tool to authenticate with — instead of asking the user to paste it or hardcoding a placeholder.
---

# lilpass: local password access for agents

`lilpass` is a local CLI (and MCP server, via `lilpass mcp`) for lil passwords, a macOS password
manager. It gives you a safe way to use a secret you don't otherwise have without that secret ever
appearing in your own context, your shell history, or whatever transcript this session gets saved
to.

## The rule: resolve secrets into a process, never into your own output

`lilpass` has two commands built exactly for this — prefer them over everything else whenever the
goal is "get this secret into some other tool's hands," not "show this secret to a human right
now":

**Running a command with a secret in its environment** — use `lilpass run`:

```sh
lilpass run --env GITHUB_TOKEN=lilpass://github.com/password -- gh api user
lilpass run --env NPM_TOKEN=lilpass://npmjs.com/password -- npm publish
```

`--env KEY=lilpass://item/field` may be repeated for more than one secret. The referenced command
runs with `KEY` set in its environment; you never see the value, and neither does anything reading
your own tool calls or output. `lilpass run`'s own exit code is always the child command's exact exit
code (not one of `lilpass`'s usual 0–7 codes), so check that the way you'd check any other command's
exit code.

**Filling in a secret-bearing file (e.g. a `.env`)** — use `lilpass inject`:

```sh
lilpass inject -i .env.example -o .env
```

Every `{{ lilpass://item/field }}` placeholder in the input file is replaced with its resolved value
in the output file. If anything fails to resolve, nothing is written — you won't end up with a
half-filled-in file, so it's safe to just retry after fixing whatever was wrong (a typo'd item
name, a locked vault) rather than needing to clean up a partial result first.

**Setting a secret works the same way, in reverse** — `lilpass add`/`lilpass edit` never accept a
password as a literal argument, only via `--password -` reading from stdin (or `--generate` to skip
providing one at all):

```sh
echo -n hunter2 | lilpass add --title GitHub --username octocat --password -
lilpass add --title "New Service" --generate --length 20
```

`add`/`edit`/`rm` all require agent access **and** a separate write-access setting the user has to
turn on explicitly (Settings → Agents) — expect exit code `8` if it's off, same as any other
gated operation here.

## `lilpass://item/field` reference syntax

```
lilpass://<item>/<field>
```

- `<item>`: an item's title (case-insensitive) or an associated website domain — e.g. `github`,
  `github.com`.
- `<field>`: one of `password`, `username`, `totp`, `notes`, `website`.

## When it's actually fine to see the value

Only reach for a value-printing command — `lilpass read lilpass://item/field`, `lilpass get`, or
`lilpass totp` — when a human explicitly asked to see the secret itself, or you genuinely need the
raw value in your own working context (e.g. you're constructing an HTTP request body field by
field yourself, rather than handing the whole thing to a subprocess via `lilpass run`). If you do,
remember the value is now wherever your own output goes — don't then paste it somewhere else, log
it, or leave it sitting in an intermediate variable/file longer than it needs to be.

## Checking whether you can use it at all

```sh
lilpass status
```

prints `locked: false` / `agentAccessEnabled: true` when both conditions `lilpass` needs are met. If
either is false, `lilpass` commands that touch the vault fail with a documented exit code (`3` =
locked, `4` = agent access disabled — see `lilpass --help` or `docs/agents.md` for the full table)
and a plain-text message on stderr explaining which one. Tell the user what's blocking you rather
than retrying blindly — turning agent access on, or unlocking the vault, is their call, not yours.

## If `lilpass` isn't available as a CLI

It might instead be wired up as an MCP server (`lilpass mcp`, exposing `list_passwords`,
`search_passwords`, `get_password`, `get_verification_code`, `generate_password`, and — when write
access is turned on — `create_password`, `update_password`, `delete_password`). Those tools follow
the same "some things reveal secrets, some don't" split: `list_passwords`/`search_passwords`/the
write tools never include a password/notes/TOTP value in their result; `get_password`/
`get_verification_code` do. The same "don't reach for the revealing ones unless you actually need
the raw value" guidance applies there too.

## If a request unexpectedly fails

`lilpass` (and every MCP tool above) can fail for reasons that have nothing to do with what you
asked for and everything to do with settings a human controls: the vault might be locked, agent
access or write access might be off, the item might be outside the access scope the user configured
("Only Selected Passwords" hides everything else as a plain not-found, "Ask Every Time" requires a
Touch ID approval you can't complete yourself). Report what's blocking you and let the user decide
whether to unlock, enable, approve, or widen access — never retry the same request in a loop hoping
it resolves itself.
