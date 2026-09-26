# AGENTS.md snippet: lilpass

Paste this section into your project's `AGENTS.md` (or `CLAUDE.md`, or your agent tool's
equivalent project-instructions file) if the project's secrets live in lil passwords and you want
any agent working in the repo to reach for `lilpass` instead of asking you to paste a token, or
hardcoding one in a script.

---

## Secrets

This project's secrets (API tokens, database passwords, etc.) live in lil passwords, not in any
file in this repo. Use the `lilpass` CLI to reach them — never ask a human to paste a secret, and
never write one into a file, a shell command's arguments, or your own output.

- To run a command with a secret in its environment, without ever seeing the value yourself:

  ```sh
  lilpass run --env API_TOKEN=lilpass://<item>/password -- <command>
  ```

- To fill in a template file (e.g. turn `.env.example` into `.env`):

  ```sh
  lilpass inject -i .env.example -o .env
  ```

- To save a new secret (only if write access is turned on — see below), pipe it in rather than
  passing it as an argument:

  ```sh
  echo -n <secret> | lilpass add --title <title> --username <username> --password -
  ```

- Check `lilpass status` first if any of the above fails — it reports whether the vault is
  unlocked and whether agent access is turned on. `lilpass add`/`edit`/`rm` also need a separate
  write-access setting; a locked vault, disabled access, or missing write access are all things a
  human (not you) has to enable — report the failure rather than retrying.

Full reference: `docs/agents.md` in the lil passwords repo, or
<https://github.com/851-labs/lil-passwords/blob/main/docs/agents.md>.
