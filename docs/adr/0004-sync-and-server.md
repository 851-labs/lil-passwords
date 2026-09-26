# 0004. Sync API design and server stack

- Status: Proposed — needs external review. The stack choice in [§1](#1-server-stack) is
  explicitly marked **needs Alexandru's decision**.
- Related: [851-2448](https://linear.app/851/issue/851-2448/sync-api-design-server-stack-adr)
  (this ticket), [851-2449](https://linear.app/851/issue/851-2449) (accounts + passkey auth),
  [851-2450](https://linear.app/851/issue/851-2450) (server implementation, not this ticket),
  [851-2451](https://linear.app/851/issue/851-2451) (Mac sync engine, the primary consumer of the
  API this ADR defines), [851-2452](https://linear.app/851/issue/851-2452)/[851-2453](https://linear.app/851/issue/851-2453)
  (web vault, the other consumer), [851-2457](https://linear.app/851/issue/851-2457) (device
  approval, designed in [§8](#8-device-approval-relay-851-2457)), `docs/adr/0002-crypto.md`
  (key hierarchy, unlock methods, the crypto-review rollback note this ADR closes),
  `docs/adr/0003-vaultstore.md` (`VaultRecord`, the local `changes` log this design mirrors).
  The OpenAPI 3.1 document for everything below is `docs/api/sync.yaml`.

## Context

Per the [project decisions](https://linear.app/851/project/lil-passwords-ceedf3416b9d), the MVP
(milestones 1–5) is 100% local: no accounts, no server, no network requests that touch vault
data. "Sync & web" (milestone 6) adds exactly one server-side capability — **relaying ciphertext
between a user's own devices** — and nothing else. This ADR designs that server's API and picks
its stack, on paper, before any server code exists. **No server code changes ship with this
ticket**; 851-2450 implements against what's decided here.

`docs/adr/0002-crypto.md` already decided the crypto (no master password, vault key wrapped for
local Keychain/recovery, item AAD, and — as a crypto-review follow-up (851-2403) — that AAD binds
the record's own `version`) and sketched, but did not build, three "Sync & web" mechanisms:
passkey PRF for the web vault, device approval via ephemeral X25519, and an account Ed25519/X25519
key pair. `docs/adr/0003-vaultstore.md` already decided the local schema (`VaultRecord`, the
append-only `changes` log with its `seq` cursor). This ADR is the seam between those two documents
and the network: it does not change `VaultRecord`'s shape, `VaultCrypto`'s sealing scheme, or
anything already shipped — it defines what a server does with `VaultRecord`s once one exists, and
closes the one open item ADR 0002 flagged for this stage:

> Review note from the crypto PR (#5): the item AAD binds `recordId`, `type`, and `schemaVersion`,
> but **not the record revision**. Once a server is involved, it could replay an older ciphertext
> for the same record (rollback). The sync design should add the record version (or a per-account
> hash chain / Merkle root) to what's authenticated.

851-2403 already closed the first half of that (AAD now authenticates `version`, per ADR 0002 §
"AAD includes the record version"). This ADR closes the second half: [§7](#7-anti-rollback-the-account-head)
adds the per-account hash chain the comment asks for, so a rollback of an entire account (not just
one record) is also detectable, not only a single replayed row.

### Scope

**In scope:** the server's stack ([§1](#1-server-stack)), data model ([§2](#2-data-model)),
account key pair provisioning ([§3](#3-account-key-pair-provisioning)), passkey
auth/sessions/device tokens and recovery-key re-auth ([§4](#4-authentication)), device list/revoke
([§5](#5-devices-list-and-revoke)), push/pull/cursors/idempotency/conflicts/tombstones
([§6](#6-sync-push-and-pull)), the anti-rollback account head ([§7](#7-anti-rollback-the-account-head)),
the device-approval relay ([§8](#8-device-approval-relay-851-2457)), size/rate limits
([§9](#9-size-limits-and-rate-limits)), the compromised-server threat model
([§10](#10-threat-model-a-compromised-server)), and a migration/backup plan
([§11](#11-migration-and-backup-plan)).

**Out of scope, deliberately:** the server's implementation (851-2450), the Mac sync engine's
retry/backoff/offline queueing logic and its UI (851-2451, which is the primary *consumer* of the
API below), the web vault's browser-side crypto and UI (851-2452/851-2453), web vault hardening
(851-2454), and the third-party audit (851-2455, which should audit against this document and
851-2450's implementation of it). Nothing here blocks any of those from starting — this ticket's
job is to give them a stable target.

## 1. Server stack

### Criteria

| Criterion | Why it matters here |
| --- | --- |
| E2EE-only storage fit | The server stores exactly one shape of data well: opaque, small, versioned ciphertext blobs keyed by account, plus a handful of small metadata tables. It never runs a query that needs to understand a blob's contents. |
| Cost at small scale | This product has no revenue yet and an unknown number of users. The stack must be close to free at zero-to-hundreds of accounts and predictable as it grows. |
| Ops burden | 851 Labs is effectively one person. Anything that needs patching, capacity planning, or on-call is a real cost. |
| WebAuthn support | Passkey register/login (851-2449) is on the critical path for every account. This is an application-level protocol (any server-side language/runtime can implement it against a WebAuthn library), so it mostly comes down to *runtime compatibility* of an existing library, not platform capability. |
| Latency | Sync should feel instant on a Mac save and on web vault load. Matters most for `pull`/`push` round trips, less for auth (infrequent). |
| Backups | Independent of stack quality, backups must be point-in-time, tested, and stored where the application's own credentials can't delete them (ransom scenario) — see [§11](#11-migration-and-backup-plan). |
| Vendor lock-in | How hard it is to move off this stack later, given the product's promise is that the server is a dumb ciphertext relay — in principle, replaceable. |

### Comparison

| | (a) TypeScript on Cloudflare Workers + D1/Durable Objects/R2 | (b) Postgres on Fly.io (Go or TS) | (c) Supabase |
| --- | --- | --- | --- |
| **E2EE-only storage fit** | Very good. D1 (SQLite) is a natural fit for small, versioned rows; a Durable Object per account gives a single-writer serialization point for the version-check-and-append in [§6](#6-sync-push-and-pull) for free, with no row locking to get right by hand. R2 is free egress if backup exports or future large blobs (attachments are explicitly out of scope, but who knows) ever matter. | Very good. Postgres is the textbook fit for versioned rows with indexes; `UPDATE … WHERE version = $1` or a `SELECT … FOR UPDATE` gives the same atomicity DOs give (a), just via row locks instead of actor isolation. | Good. It's Postgres underneath, same fit as (b), plus Row Level Security *could* enforce account isolation at the DB layer — attractive in principle, but this app's isolation is already enforced at the API layer by every query being scoped to the authenticated account, so RLS would be a second, redundant enforcement point rather than a load-bearing one. |
| **Cost at small scale** | Best. Workers/D1/DO all have generous free tiers; a few hundred accounts doing password-manager-sized syncs cost close to $0/month. | Cheap but not free: a Fly Postgres instance (even the smallest) is a running VM, so there's a real monthly floor (roughly $5–15/mo) from account zero. | Free tier exists and covers a small launch, but Supabase's free-tier projects pause after a period of inactivity and have hard row/storage caps that a growing (if still small) user base can hit sooner than the other two. |
| **Ops burden** | Lowest. No servers, no OS patching, no connection pool sizing, no capacity planning; scales to zero and back with no action taken. | Highest. Someone owns Postgres version upgrades, disk growth, connection limits, and the VM itself (Fly reduces some of this vs. bare-metal Postgres, but not all of it). | Low-medium. Managed Postgres + managed Auth removes most day-to-day ops, but a platform-specific incident (an outage, a breaking Auth/API change) is entirely out of this team's control to work around, unlike (a)/(b) where the app is a normal client of a well-understood database. |
| **WebAuthn support** | Believed workable — `@simplewebauthn/server` and similar libraries run under Workers' `nodejs_compat` flag, which covers the Node crypto surface WebAuthn signature verification needs — but this is **not independently verified in this ADR** and should be the first thing 851-2450 spikes, since a WebAuthn ceremony bug is security-critical and Workers' isolate runtime is the least "just Node" of the three options. | Best. Any Node/Go WebAuthn library (`@simplewebauthn/server`, `go-webauthn/webauthn`) runs unmodified on a normal server process — zero runtime-compatibility risk. | Supabase Auth has been adding MFA/WebAuthn support, but it's less mature and less customizable than rolling a dedicated WebAuthn server ourselves, and this app's usernameless, discoverable-credential-only flow (no email/password fallback) is a narrower shape than what Supabase Auth is designed around. In practice this option would likely bypass Supabase Auth entirely and implement WebAuthn by hand anyway (as in (b)), which erodes most of the reason to pick Supabase. |
| **Latency** | Best for global users — Workers run at the edge, close to wherever the request originates, and D1 (with read replication) follows. Matters most for `pull` polling from a web vault tab. | Good but single-region unless a multi-region Postgres topology is added later — real complexity this product doesn't need yet at "small scale." | Same as (b): whichever single region the project is created in, unless a paid multi-region add-on is used. |
| **Backups** | D1 has built-in point-in-time "time travel" (30 days) plus scheduled exports to R2 for an independent copy — see [§11](#11-migration-and-backup-plan) for why an independent copy matters regardless of stack. | Mature and well-understood: Fly Postgres backups, or Litestream/WAL-G to R2/S3, with a long track record and no surprises. | Managed daily backups, PITR on paid tiers — fine, but one more thing gated behind a specific Supabase plan rather than owned outright. |
| **Vendor lock-in** | Highest. D1's SQL dialect and Durable Objects' actor model are Cloudflare-specific; migrating off means rewriting the storage layer, not just re-pointing a connection string. | Lowest. Postgres runs anywhere (another VPS, another managed Postgres, self-hosted); Fly.io itself is the only lock-in, and it's the *app hosting*, which is cheap to move. | Medium-high. The database itself is portable Postgres, but Auth, Row Level Security policies, and Edge Functions (if used) are Supabase-specific; a migration would need to rebuild those pieces even though the raw data survives. |

### Recommendation — needs Alexandru's decision

**Recommended: (a) TypeScript on Cloudflare Workers + D1 + Durable Objects + R2**, primarily on
cost, ops burden, and latency — the three criteria that matter most for a pre-revenue product run
by one person, where a Durable Object per account also happens to solve
[§6](#6-sync-push-and-pull)'s "atomically check-and-bump a version" requirement more naturally than
either alternative (a single-writer actor, rather than hand-rolled row locking). The honest cost of
this recommendation is **vendor lock-in**: D1's dialect and Durable Objects' actor model are not
portable, and moving off Cloudflare later means rewriting the storage layer, not just changing a
connection string. Because the server is deliberately a dumb ciphertext relay with a small,
well-specified API surface (this whole document), that rewrite is more contained than it would be
for a typical application server — but it is still real work, and it's the tradeoff this
recommendation is explicitly asking Alexandru to accept.

**If long-term portability or ease of third-party audit (851-2455) matters more than the
cost/ops/latency win**, **(b) Postgres on Fly.io** is the fallback: the most boring, most portable,
most auditable option, at the cost of a real (if small) monthly floor and full ownership of
Postgres operations. **(c) Supabase** is not recommended: it doesn't fit this app's usernameless
passkey-only auth model well enough to earn its lock-in, and this app doesn't use most of what
else Supabase offers (storage buckets, realtime, generated REST/GraphQL over the schema) since
sync is a bespoke protocol regardless of backend.

Whichever wins, 851-2450 should spike the WebAuthn library's compatibility with the chosen runtime
*before* committing to the rest of the implementation, per the WebAuthn row above.

## 2. Data model

One database (Postgres or D1/SQLite — the schema below is written portably; Postgres-only
notes are called out). Six tables.

```sql
CREATE TABLE accounts (
  id                       TEXT PRIMARY KEY,     -- UUID
  email                    TEXT,                 -- optional, security notifications only (§4); never required, never a login factor
  recovery_verifier_hash   BLOB NOT NULL,         -- Argon2id(recoveryKey.entropy, recovery_verifier_salt) — see §4
  recovery_verifier_salt   BLOB NOT NULL,
  wrapped_vault_key        BLOB NOT NULL,         -- VaultCrypto.WrappedKey, JSON-encoded, ciphertext only (§3/§4)
  account_public_key_x25519 BLOB NOT NULL,        -- account key pair, public halves only (§3) — plaintext, not secret
  account_public_key_ed25519 BLOB NOT NULL,
  created_at               TIMESTAMPTZ NOT NULL,
  deleted_at               TIMESTAMPTZ            -- soft marker set briefly during account deletion; see §5
);

CREATE TABLE webauthn_credentials (
  id                TEXT PRIMARY KEY,             -- UUID
  account_id        TEXT NOT NULL REFERENCES accounts(id),
  credential_id     BLOB NOT NULL UNIQUE,         -- WebAuthn credential ID, base64url on the wire
  public_key        BLOB NOT NULL,                -- COSE-encoded public key
  sign_count        INTEGER NOT NULL DEFAULT 0,
  transports        TEXT,                         -- JSON array, e.g. ["internal","hybrid"]
  name              TEXT,                         -- user-supplied label, e.g. "MacBook Pro Touch ID"
  created_at        TIMESTAMPTZ NOT NULL,
  last_used_at      TIMESTAMPTZ
);
CREATE INDEX webauthn_credentials_account ON webauthn_credentials(account_id);

CREATE TABLE devices (
  id                TEXT PRIMARY KEY,             -- UUID, client-generated at first auth; matches VaultRecord.deviceId
  account_id        TEXT NOT NULL REFERENCES accounts(id),
  name              TEXT NOT NULL,                -- e.g. "Alexandru's MacBook Pro", "Safari on iPhone"
  platform          TEXT NOT NULL,                -- "mac" | "web"
  created_at        TIMESTAMPTZ NOT NULL,
  last_seen_at      TIMESTAMPTZ NOT NULL,
  revoked_at        TIMESTAMPTZ
);
CREATE INDEX devices_account ON devices(account_id);

CREATE TABLE sessions (
  id                TEXT PRIMARY KEY,             -- UUID; the bearer access token's identifier, not the token itself
  account_id        TEXT NOT NULL REFERENCES accounts(id),
  device_id         TEXT NOT NULL REFERENCES devices(id),
  access_token_hash BLOB NOT NULL,                -- SHA-256 of the access token; the raw token is never stored
  refresh_token_hash BLOB NOT NULL,                -- SHA-256 of the (rotating) refresh/"device" token
  created_at        TIMESTAMPTZ NOT NULL,
  access_expires_at TIMESTAMPTZ NOT NULL,          -- short-lived, e.g. 12h
  refresh_expires_at TIMESTAMPTZ NOT NULL,          -- long-lived, e.g. 90d, sliding on refresh
  revoked_at        TIMESTAMPTZ
);
CREATE INDEX sessions_device ON sessions(device_id);
CREATE INDEX sessions_account ON sessions(account_id);

-- The server-side mirror of a device's local `records` table (docs/adr/0003-vaultstore.md),
-- scoped per account, plus the columns a sync server needs that a single local vault doesn't.
CREATE TABLE records (
  account_id        TEXT NOT NULL REFERENCES accounts(id),
  id                TEXT NOT NULL,                -- UUID, matches VaultRecord.id
  type              TEXT NOT NULL,                -- VaultRecord.RecordType, e.g. "password-item"
  version            INTEGER NOT NULL,             -- VaultRecord.version
  modified_at        TIMESTAMPTZ NOT NULL,          -- VaultRecord.modifiedAt (writer's clock; informational only, never used for ordering)
  device_id          TEXT NOT NULL REFERENCES devices(id), -- VaultRecord.deviceId
  deleted            BOOLEAN NOT NULL,             -- VaultRecord.deleted (tombstone)
  key_id             TEXT,                         -- VaultCrypto.SealedItem.keyId; NULL iff deleted
  format_version     SMALLINT,                     -- VaultCrypto.SealedItem.formatVersion; NULL iff deleted
  sealed             BLOB,                         -- VaultCrypto.SealedItem.combined; NULL iff deleted (§6)
  schema_version     INTEGER,                      -- NULL iff deleted
  server_seq         BIGINT NOT NULL,              -- the per-account sync cursor (§6); assigned from account_heads.seq
  idempotency_key    TEXT NOT NULL,                -- the push request that produced this row's current version (§6)
  received_at        TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (account_id, id)
);
CREATE UNIQUE INDEX records_account_seq ON records(account_id, server_seq);
CREATE INDEX records_account_modified ON records(account_id, modified_at);

-- One row per account: the anti-rollback hash chain (§7). Updated transactionally with every
-- accepted record write, in the same transaction that assigns that record's server_seq.
CREATE TABLE account_heads (
  account_id   TEXT PRIMARY KEY REFERENCES accounts(id),
  seq          BIGINT NOT NULL,                    -- highest server_seq issued for this account
  hash         BLOB NOT NULL,                       -- SHA-256, see §7's chain formula
  signature    BLOB NOT NULL,                       -- Ed25519 signature over (account_id, seq, hash) by the server's own key
  updated_at   TIMESTAMPTZ NOT NULL
);

-- Pending/recent device-approval relay requests (§8). Rows are deleted (not soft-deleted) once
-- redeemed or expired — the ciphertext they hold has no reason to live longer than the handshake.
CREATE TABLE device_approvals (
  id                        TEXT PRIMARY KEY,      -- UUID ("approvalId")
  account_id                TEXT NOT NULL REFERENCES accounts(id),
  requesting_device_id      TEXT NOT NULL REFERENCES devices(id),
  requesting_device_name    TEXT NOT NULL,
  status                    TEXT NOT NULL,          -- "pending" | "confirmed" | "redeemed" | "denied" | "expired"
  approver_device_id        TEXT REFERENCES devices(id),
  approver_ephemeral_public_key BLOB,               -- set on confirm
  wrapped_vault_key         BLOB,                    -- AES-256-GCM ciphertext, set on confirm, cleared on redeem
  approval_signature        BLOB,                    -- Ed25519 signature by the account key (§3), set on confirm
  created_at                TIMESTAMPTZ NOT NULL,
  expires_at                TIMESTAMPTZ NOT NULL,    -- short TTL, e.g. 5 minutes
  confirmed_at              TIMESTAMPTZ,
  redeemed_at               TIMESTAMPTZ
);
CREATE INDEX device_approvals_account_status ON device_approvals(account_id, status);
```

Notes:

- `records` deliberately mirrors `VaultRecord` field-for-field (`docs/adr/0003-vaultstore.md`'s
  `records` table) plus exactly what a *server* needs on top: `account_id` (isolation),
  `server_seq` (the cursor — the server's equivalent of the local `changes.seq`, assigned per
  account rather than per vault-on-disk), `idempotency_key`, and `received_at`. This symmetry is
  intentional: 851-2451's sync engine maps one-to-one between a local `VaultRecord` row and a
  server `records` row with no shape translation, only the addition/removal of the
  server-only/local-only columns.
- Postgres: use `BIGSERIAL`/a per-account sequence for `server_seq`, or derive it from
  `account_heads.seq` inside the same transaction (simplest: `UPDATE account_heads SET seq = seq +
  1 ... RETURNING seq`, then insert `records` with that value — this also naturally serializes
  writes per account via row locking on `account_heads`). D1/SQLite: a Durable Object instance
  scoped to `account_id` (per [§1](#1-server-stack)'s recommendation) holds `seq` in memory/its own
  storage and assigns it directly, since exactly one DO instance ever handles a given account's
  writes.
- No `PRAGMA user_version`/`schema_migrations` split like the local `VaultStore` needs (ADR 0003)
  — a hosted server has one canonical migration history tracked by whatever tool the chosen stack
  uses (see [§11](#11-migration-and-backup-plan)), not a per-file `PRAGMA` a human might inspect
  with a bare `sqlite3` shell.

## 3. Account key pair provisioning

ADR 0002 names an "account key pair" (X25519 for key agreement, Ed25519 for signing
device-approval records) as designed-but-not-built, without specifying who holds the private
half. This ADR resolves that: **the account key pair's private halves are themselves an ordinary
encrypted vault secret, synced like any other record — never generated or held server-side.**

- The first device to enable sync (i.e., the first device to call `POST /v1/accounts`, per
  [§4](#4-authentication)) generates the X25519 and Ed25519 key pairs locally, while the vault is
  unlocked, the same way it already generates the vault key itself. It seals the private halves
  under the vault key (a `VaultCrypto.SealedItem`, same mechanism as any other record) and stores
  them in the vault's own `meta` table (`docs/adr/0003-vaultstore.md`) — a new column, not a new
  ticket's worth of schema, since `meta` is already the vault's single-row header for exactly this
  kind of "one per vault, needed before any record decrypts" secret.
- The **public** halves are not secret. They're sent to the server once, at account creation, and
  stored in `accounts.account_public_key_x25519`/`account_public_key_ed25519` in the clear —
  fetchable by any device that's authenticated but hasn't unlocked the vault key yet (a brand-new
  device mid-approval, per [§8](#8-device-approval-relay-851-2457), needs the account's Ed25519
  public key to verify an approval signature *before* it has the vault key to decrypt anything
  else).
- Every device that later unlocks the vault (via local Keychain, recovery key, or device approval)
  gets the private halves along with everything else, the same way it gets every other sealed
  record — no separate provisioning step, no risk of the two ever going out of sync, because
  they're literally the same sync mechanism.
- Consequence: **the server can never produce a valid device-approval signature or complete an
  ECDH as the account**, because it never holds (and structurally cannot derive) the private
  halves — see [§10](#10-threat-model-a-compromised-server).

## 4. Authentication

Accounts are identified by an opaque `accountId`, not an email or username — passkeys are
usernameless, discoverable credentials throughout. `email` (`accounts.email`) is optional,
collected only if the user chooses to, and used only for out-of-band security notifications (new
device approved, new sign-in) — never as a login factor and never required. This matches the "no
master password" spirit of ADR 0002: nothing in the login path is a secret a person has to
remember, other than the recovery key, which already exists for exactly this purpose.

**Two independent things happen at "login":**

1. **Authentication** (server-side: who is this?) — WebAuthn passkey assertion, or recovery-key
   re-auth. Either grants a session (an access token + a device/refresh token, [§2](#2-data-model)'s
   `sessions` table).
2. **Decryption** (client-side only, the server is never involved) — the vault key must still be
   obtained locally, via the local Keychain (Mac, already unlocked), the recovery key (unwrapping
   `accounts.wrapped_vault_key`, fetched only after (1) succeeds), or device approval
   ([§8](#8-device-approval-relay-851-2457)).

A device can be fully authenticated (able to push/pull ciphertext) with a **locked** vault — this
is expected, not a bug: a brand-new browser tab that already has a synced platform passkey for this
Apple ID can sign in immediately, long before it has any way to decrypt what it pulls.

### Sign-up

`POST /v1/auth/register/options` → `POST /v1/auth/register/verify` (standard two-step WebAuthn
registration ceremony: the server issues a challenge + `PublicKeyCredentialCreationOptions`,
holds it briefly server-side keyed to a short-lived `registrationId`, then verifies the returned
attestation). `register/verify`'s body also carries the new account's public key halves
([§3](#3-account-key-pair-provisioning)), the recovery verifier (below), and the requesting
device's name/platform — creating `accounts`, `webauthn_credentials`, and `devices` rows
atomically, and returning a session. See `docs/api/sync.yaml` `POST /v1/auth/register/verify` for
the exact request/response shape.

### Sign-in (passkey)

`POST /v1/auth/login/options` (empty/discoverable — `allowCredentials` is empty so any resident
credential for this RP can respond) → `POST /v1/auth/login/verify`. On success: `sign_count`
comparison (WebAuthn's standard clone-detection signal — a `sign_count` that doesn't strictly
increase indicates the credential was likely cloned; the server rejects the assertion and flags the
credential rather than silently accepting it), then a new session.

### Sign-in (recovery key)

`POST /v1/auth/recovery/login` with `{ accountId, recoveryKey }`. The server computes
`Argon2id(recoveryKey.entropy, recovery_verifier_salt)` and compares against
`recovery_verifier_hash` in constant time. **This is the only password-shaped credential in the
system**, and it's the same 160-bit machine-generated secret ADR 0002 already uses to wrap the
vault key locally — a slow hash here is defense-in-depth (the entropy alone is already
un-guessable at 160 bits), and this endpoint gets the most aggressive rate limiting in the API
(see [§9](#9-size-limits-and-rate-limits)). On success, returns a session — the caller then fetches
`GET /v1/account/wrapped-key` to get `accounts.wrapped_vault_key` and unwraps it locally exactly as
ADR 0002's local recovery flow already does, just fetching the `WrappedKey` blob from the server
instead of a local vault file's header.

Because the recovery key is the full-authority backup credential in the *local* design already
("the recovery key plus the vault file is sufficient to restore the vault"), letting it also
authenticate to the server is not a new capability being granted — an attacker who has the
recovery key already has everything they need to steal the vault via a stolen Mac; giving it a
server-side login path doesn't materially change that.

### Sessions and device tokens

- `POST /v1/auth/login/verify` / `register/verify` / `recovery/login` all return `{ accessToken,
  refreshToken, deviceId }`. `accessToken` is a bearer token (`Authorization: Bearer …`) for
  `sync`/`devices`/`account` calls, short-lived (12h). `refreshToken` is long-lived (90d, sliding),
  presented only to `POST /v1/auth/refresh` to mint a new pair — **rotated on every use**, with the
  old one immediately invalidated, so a stolen-and-replayed old refresh token after a legitimate
  refresh is detectable (reuse of an already-rotated token revokes the whole session as a
  precaution).
- Both tokens are stored server-side only as a SHA-256 hash (`sessions.access_token_hash`/
  `refresh_token_hash`) — a database leak doesn't hand out live sessions directly, only hashes an
  attacker would still need to reverse (infeasible for a random 256-bit token).
- Revocation ([§5](#5-devices-list-and-revoke)) sets `sessions.revoked_at`, checked on every
  request — access tokens are opaque and looked up, not self-contained JWTs, specifically so
  revocation is immediate rather than "eventually, once the JWT expires." The extra lookup this
  costs is negligible at this product's scale and is the right trade for a password manager, where
  "revoke this device *now*" has to actually mean now.

## 5. Devices: list and revoke

- `GET /v1/devices` — every non-revoked device for the caller's account: `id`, `name`, `platform`,
  `createdAt`, `lastSeenAt`.
- `DELETE /v1/devices/{deviceId}` — revokes the device: sets `devices.revoked_at` and
  `sessions.revoked_at` for every session belonging to it. The revoked device's next `push`/`pull`
  gets `401` and must re-authenticate (and, being revoked, can't — it has no valid credential path
  back in unless the user re-approves it as if it were new).
- Revoking a device does **not** rotate the vault key, matching ADR 0002's device-revocation
  design: the vault key already left that device's control the moment it had it, and a merely
  *removed* (not suspected-compromised) device doesn't need a rotation. A future "I think this
  device was compromised, not just retired" flow would pair a revoke with an explicit vault-key
  rotation (ADR 0002's rotation mechanism, re-sealing every record and re-wrapping for recovery) —
  out of scope here, not blocked by anything in this design.
- Account deletion (851-2449): `DELETE /v1/account`, gated by a fresh re-authentication (a
  WebAuthn assertion or recovery-key check performed in the same request, not just a still-valid
  session — deleting an account is irreversible and shouldn't be doable from a merely-still-logged-in
  tab). Hard-deletes `records`, `account_heads`, `device_approvals`, `devices`, `sessions`,
  `webauthn_credentials`, and finally `accounts` for that account, in that order, in one
  transaction. "Wipes all ciphertext" is literal: nothing about the account survives, including in
  read replicas at the earliest consistent point — backups are the only remaining copy, and they
  expire on the normal retention schedule ([§11](#11-migration-and-backup-plan)), not immediately
  (deleting from backups on demand isn't practical and isn't promised).

## 6. Sync: push and pull

### Push

`POST /v1/sync/push`, `Idempotency-Key: <uuid>` header required, body: an array of records shaped
like `VaultRecord` (`docs/api/sync.yaml`'s `SyncRecord` schema — the same fields as `VaultRecord`
itself: `id`, `type`, `version`, `modifiedAt`, `deviceId`, `deleted`, and, unless `deleted`,
`sealed`/`schemaVersion`).

For each record in the batch, independently:

- The server requires `version == currentServerVersion + 1` (or `== 1` for a record it's never
  seen). This is the "version check" the ticket asks for, and it's the same invariant
  `VaultStoreCore` already enforces locally (`docs/adr/0003-vaultstore.md`) — a sync client is
  just another writer that has to play by the same "you must have seen the current version before
  bumping it" rule, now enforced by the server instead of a single process's own state.
- **Accepted** (`version` matches): insert the new `records` row, assign the next `server_seq` for
  this account, advance `account_heads` ([§7](#7-anti-rollback-the-account-head)). Response entry:
  `{ id, status: "accepted", serverSeq }`.
- **Conflict** (`version` doesn't match — either stale, because another device already wrote a
  newer version, or out-of-order, because the client skipped a version it never pulled): `409`
  entry, **not** a whole-request failure — `{ id, status: "conflict", server: <current SyncRecord>
  }`, where `server` is the record's current full state. This is "last-writer-wins per record,
  with version checks and conflict copies" from the ticket: **last-writer-wins is what happens at
  this transport layer** (whichever version lands first server-side occupies that slot); the
  *conflict copy* — duplicating the client's own losing edit as a new record so it isn't silently
  discarded — is 851-2451's job (the Mac sync engine), using this response's `server` field to know
  what it lost against. This ADR defines the wire contract; it doesn't design that UX.
- One record's conflict doesn't block the rest of the batch — each is judged independently, so an
  offline-first client (851-2451) that queued several unrelated edits doesn't have all of them
  rejected because exactly one is stale.

**Idempotency:** `Idempotency-Key` is a client-generated UUID scoped to one logical push attempt.
The server stores `(accountId, idempotencyKey) → response`, TTL 24h, and replays the stored
response verbatim on an exact retry instead of re-applying anything — necessary because a network
timeout leaves the client unable to tell "the push never arrived" from "it arrived and succeeded
but the response was lost," and blindly retrying a push without this would either double-apply (if
retried with a bumped version, masking the real conflict signal) or spuriously conflict (if
retried with the same version, indistinguishable from a real stale write). A retry **must** reuse
the same key and the same record set as the original attempt; the server does not attempt to merge
a retry that differs from what it has cached, it just returns 200 with the ID given a byte-identical
match, so this replay path is deliberately narrow than an offer to reconcile — a differing body
gets `422`.

### Pull

`GET /v1/sync/pull?since={serverSeq}&limit={n}` (default/max `limit`: 500 records or 4 MiB,
whichever is reached first). Returns records with `server_seq > since`, ordered by `server_seq`
ascending, plus `{ nextSince, hasMore, head }`. `since=0` (or omitted) is a full resync — a brand
new device, or one that's re-approved after being offline long enough that its old cursor is no
longer useful, gets every record from the beginning, tombstones included, and reconstructs current
state exactly the way `docs/adr/0003-vaultstore.md`'s local `changes(since:)` cursor already works,
just account-scoped instead of database-scoped.

### Tombstones

A client that fully purges an item's content (as opposed to `PasswordItem.deletedAt`'s *soft*,
still-decryptable "Recently Deleted" state — a distinct, already-shipped concept per ADR 0003)
pushes a record with `deleted: true` and **omits** `sealed`/`schemaVersion`/`keyId`/`formatVersion`
entirely — there is nothing left to authenticate or encrypt once content is actually gone, so the
transport schema makes those fields absent, not present-but-empty. The server stores `sealed`
(and friends) as `NULL` for that row. Tombstones are kept indefinitely at this scale (they're a
handful of bytes each) so a device that was offline for a long time still learns about every
delete on its next full-history pull; compacting very old tombstones once every known device has
confirmed seeing them is a real future optimization, deliberately deferred — not needed until the
`records` table's tombstone fraction is large enough to matter, which nothing at "small scale"
approaches.

## 7. Anti-rollback: the account head

This closes the crypto-review comment on 851-2448 directly: item-level AAD (851-2403) already
stops a stale *ciphertext* from being replayed into a live slot — `open` fails with
`authenticationFailed` if the `version` folded into the AAD doesn't match what's expected. What it
doesn't stop is a compromised server presenting an entire **account** at an old, self-consistent
state (every record's AAD still checks out — they're genuinely old-but-valid ciphertexts, just not
the newest ones). The account head is the mechanism that catches *that*.

**Chain formula**, updated once per accepted record, in `server_seq` order, in the same
transaction that assigns the record's `server_seq`:

```
head(0)  = SHA-256("lilpasswords-account-head-v1" || accountId)
head(n)  = SHA-256(head(n-1) || recordId || be64(version) || SHA-256(sealed ?? "") || be64(serverSeq))
```

`account_heads` stores only the latest `(seq, hash)`, plus an Ed25519 **signature** over
`(accountId, seq, hash)` by a server-owned signing key (published at
`GET /v1/server-keys`). Both `push` and `pull` responses include the resulting `head: { seq, hash,
signature, signedAt }` — the state *after* whatever the response just returned.

**Client-side verification (851-2451/851-2452's job to implement, specified here):** each device
persists its own last-known `(seq, hash)` per account. On every `pull` page, it recomputes the
chain forward from that stored value through the records the page just returned (it already has
every input the formula needs — `recordId`, `version`, and `sealed`, whose hash it can compute
itself — from the very payload it's verifying) and asserts the result equals the response's stated
`head.hash` *before* accepting or persisting any record in that page. On `push`, it does the same
using the records it just sent (which it already knows the plaintext/ciphertext of) in the
`serverSeq` order the response assigns them. Only after this recomputation succeeds does the
device advance its stored `(seq, hash)`. A mismatch — the response doesn't extend the client's own
last-known head — means the server has presented a fork or a rollback; the client stops syncing
that account and surfaces an error rather than silently accepting it.

**What this does and doesn't prove, precisely** (see also [§10](#10-threat-model-a-compromised-server)):

- It **does** let any single device detect the server serving it a state that doesn't extend a
  state that same device already saw and confirmed — a rollback-after-the-fact is caught the
  moment the affected device next syncs.
- It does **not** let a device detect the server withholding updates it has never seen at all (an
  account frozen at an old-but-self-consistent head looks, to a single device that's never seen
  further than that, like "nothing new happened"). Cross-device comparison (e.g., a short
  account-fingerprint shown in both the Mac app's and web vault's Settings that a user could
  eyeball match) would close this gap and is a reasonable future addition, not built here.
- **The Ed25519 signature protects a narrower thing than "the server is honest."** It protects
  against a party that can tamper with the head *in transit or in a cache/CDN layer* but does not
  hold the signing key — it does **not** protect against the origin server itself, which holds the
  key and computes the hash chain in the first place and could sign anything it likes. This is
  stated plainly here so it is never mistaken for a stronger guarantee than it is: the chain plus
  client-persisted last-known-head is what does the actual anti-rollback work against a malicious
  *operator*; the signature's job is defending the same value against a *different, weaker*
  attacker sitting between the operator and the client.

## 8. Device-approval relay (851-2457)

Onboards a new device without the recovery key, per 851-2457's description. The server's only job
throughout is **relaying bytes it cannot read**; every cryptographic step happens on the two
devices.

1. **New device** already has a session (via a synced passkey, a freshly registered one, or
   recovery-key login — [§4](#4-authentication); it does not yet have the vault key). It generates
   an ephemeral X25519 key pair `(skN, pkN)` and calls `POST /v1/devices/approvals` with `{
   deviceName, platform }`. Server creates a `device_approvals` row (`status: pending`, 5-minute
   `expires_at`) and returns `{ approvalId }`.
2. **Out-of-band transfer of `pkN`:** the new device renders a QR code encoding `{ approvalId, pkN
   }` directly — this is the channel ADR 0002 requires to keep a server-in-the-middle from
   substituting its own key, and it structurally can't be intercepted by the server because the
   server is never involved in a camera scan. **Fallback (no camera available):** the existing
   device instead fetches `pkN` from `GET /v1/devices/approvals` (server-relayed) and the user
   manually compares a short fingerprint of it against what the new device displays. This fallback
   is explicitly **lower assurance** — a short fingerprint doesn't rule out a server that computed
   many candidate key pairs looking for a colliding prefix — and the UI should present QR scanning
   as the default, the numeric fallback as an accessibility path, not an equivalent one. See
   [§10](#10-threat-model-a-compromised-server).
3. **Existing device** (already unlocked), having obtained `pkN`, generates its own ephemeral pair
   `(skE, pkE)`, computes `sharedSecret = ECDH(skE, pkN)`, `transportKey = HKDF-SHA256(sharedSecret,
   salt: approvalId, info: "lilpasswords-device-approval-v1")`, and `wrappedVaultKey =
   AES-256-GCM(transportKey, vaultKeyBytes, aad: accountId || approvalId)`. It also signs `{
   approvalId, requestingDeviceId, pkN, timestamp }` with the account's Ed25519 private key
   ([§3](#3-account-key-pair-provisioning)) — the auditable "I approved this device" record ADR
   0002 calls for. It calls `POST /v1/devices/approvals/{approvalId}/confirm` with `{ pkE,
   wrappedVaultKey, signature }`. Server sets `status: confirmed`.
4. **New device** polls `GET /v1/devices/approvals/{approvalId}` until `confirmed`, receives `{
   pkE, wrappedVaultKey, signature }`, computes the same `sharedSecret`/`transportKey` from its own
   `skN` and the received `pkE`, decrypts the vault key, and verifies `signature` against the
   account's Ed25519 **public** key (`GET /v1/account`, fetchable pre-unlock per
   [§3](#3-account-key-pair-provisioning)). On success it stores the vault key (local Keychain on
   Mac, memory-only on web, per the respective platform's design) and marks the approval
   `redeemed` (`DELETE`-equivalent: the server clears `wrapped_vault_key` and
   `approver_ephemeral_public_key` from the row immediately on redemption — this ciphertext has no
   reason to persist past the handshake it was created for).
5. **Expiry and cleanup:** unconfirmed requests expire after 5 minutes (`status: expired`, swept
   periodically); a confirmed-but-never-redeemed request (new device went offline mid-handshake)
   is also swept after a short grace window, clearing its ciphertext the same way. Either device
   can `DELETE /v1/devices/approvals/{approvalId}` to cancel/deny explicitly.
6. **Rate limiting:** approval-request creation is capped per account (see
   [§9](#9-size-limits-and-rate-limits)) — an attacker who has only compromised the server, or who
   is spamming an account's other devices with fake pending approvals as a social-engineering
   attempt, is throttled either way; a real user's existing devices seeing an unexpected pending
   approval is itself a signal worth surfacing prominently in the UI (851-2451/851-2453's job, not
   this ADR's).

The server at every step only ever holds/relays `pkN`, `pkE`, `wrappedVaultKey`, and `signature` —
never the vault key, never `sharedSecret`/`transportKey`, and (per [§3](#3-account-key-pair-provisioning))
never the account's private keys either.

## 9. Size limits and rate limits

| Limit | Value | Why |
| --- | --- | --- |
| Max `sealed` size per record | 256 KiB | Generous for a password item including long notes/custom fields; nothing in this product's item model produces anything close to this even in pathological cases. Bounds per-record storage and abuse. |
| Max records per `push` request | 500, or 8 MiB total, whichever first | Keeps a single request's transaction/lock hold time bounded; a larger backlog paginates across multiple pushes. |
| Max `pull` page size | 500 records, or 4 MiB, whichever first | Matches push; `hasMore` paginates the rest. |
| Auth endpoints (`register`, `login`, `recovery/login`) | 10/min per IP, 5/min per account, exponential backoff after 3 consecutive failures | Blunts credential stuffing and (especially) recovery-key brute forcing — the one password-shaped credential in the system. |
| `push`/`pull` | 120/min per device | Generous enough for an offline-first client (851-2451) catching up after being offline, bounded enough to cap abuse from a single compromised/misbehaving device. |
| `devices/approvals` creation | 5/hour per account | A legitimate user approves a new device rarely; this is mostly an anti-spam/anti-social-engineering bound, not a real usability constraint. |
| Account deletion | 1 per account (irreversible, no retry needed) | N/A |

All limits respond `429` with a `Retry-After` header; `push`/`pull`/`devices` responses also carry
standard `X-RateLimit-Limit`/`X-RateLimit-Remaining`/`X-RateLimit-Reset` headers so 851-2451's sync
engine can back off proactively instead of hitting the limit first.

### Observability and logging

Per the ticket: **the server never sees plaintext or keys, and logs no request bodies.**
Concretely: access logs record route, status code, account ID, device ID, timing, and byte counts
(request/response size) — the metadata [§10](#10-threat-model-a-compromised-server) already
concedes a compromised server can see — and nothing else. Request and response bodies (which
contain `sealed` ciphertext, WebAuthn ceremony payloads, and bearer tokens in headers) are
excluded from logging entirely, not merely redacted after the fact — this is a logging
*configuration* requirement 851-2450 must implement (e.g., a middleware allowlist of fields to log,
not a denylist), not something this document can guarantee on paper.

## 10. Threat model: a compromised server

Builds on `docs/adr/0002-crypto.md`'s "what a compromised server can learn," which already covers
plaintext/key confidentiality; this section covers **integrity and availability** — what an
operator or attacker who fully controls the server can and can't *do*, given this design.

**Can:**

- **Deny service entirely** — refuse or fail every request. Clients fall back to local-only
  operation (already the MVP's normal mode) with no data loss, since the local vault remains
  complete and authoritative; sync resumes when the server is reachable again.
- **Withhold updates selectively**, freezing an account (or one device's view of it) at an old,
  internally-consistent `server_seq`/head. **Detected** by any device that already advanced past
  that point and later gets served the stale one again ([§7](#7-anti-rollback-the-account-head)).
  **Not detected** by a device that has never seen further than the frozen point — it can't
  distinguish "nothing new happened" from "the server is hiding something," an explicit, disclosed
  limitation of any server-relay design, not something this ADR claims to solve.
- **Roll back an entire account** to a prior snapshot. Same detection boundary as above.
- **Inject a row that fails to decrypt.** It can insert or corrupt a `records` row, but any
  ciphertext it produces without the vault key fails AES-GCM authentication on the client — this
  degrades to a (loud, attributable, per-record) denial-of-service/tamper variant of the first
  bullet, not a way to make a client accept forged content. The AEAD tag plus AAD
  (`recordId`/`type`/`schemaVersion`/`version`, per ADR 0002) is exactly what turns "silently
  misread garbage" into "a clean `authenticationFailed` naming which row and why."
- **Observe metadata**: which account owns which blobs, per-record ciphertext sizes (loosely
  correlated with plaintext length — a very long note is visible as "long" even if unreadable),
  record counts per account, write timestamps and frequency (usage patterns — "this account is
  actively being edited right now"), device count and names (if a user names a device something
  identifying), IP addresses and connection timing, and the existence and timing of device-approval
  events (never their content). None of this is new relative to ADR 0002; this ADR just confirms
  the sync design as specified doesn't reduce it.
- **Forge its own signature on the account head** — it holds the signing key, so the signature
  ([§7](#7-anti-rollback-the-account-head)) provides no protection against the operator itself,
  only against a party downstream of it without that key.
- **Correlate accounts, devices, and IPs** for deanonymization/surveillance purposes, even though
  it can't read any vault content.

**Cannot:**

- **Read any item's plaintext** — title, username, password, notes, TOTP secret — everything in
  `sealed` is AES-256-GCM under a key the server never has and cannot derive (ADR 0002).
- **Read the vault key, the recovery key, or any device-approval `sharedSecret`/`transportKey`** —
  the recovery-key verifier is a one-way hash of it (not the key itself), and the approval relay's
  ECDH happens entirely on the two endpoint devices ([§8](#8-device-approval-relay-851-2457)).
- **Produce a device-approval bundle a new device will accept**, because that requires both a
  valid ECDH share from a genuine already-unlocked device's ephemeral private key and a valid
  Ed25519 signature from the account's private key — neither of which the server holds or can
  derive ([§3](#3-account-key-pair-provisioning)).
- **Forge a WebAuthn assertion** — the authenticator's private key never leaves the user's device
  or secure enclave; the server can accept its own fabricated bookkeeping (it already controls its
  own database), but it cannot produce a signature a *client-side* verifier (or a relying party
  spec-compliant browser) would treat as a genuine user presence, which matters specifically for
  [§8](#8-device-approval-relay-851-2457)'s account-key-signature check, verified client-side, not
  server-side.
- **Silently mutate history a device has already confirmed** without that device detecting the
  break in its own persisted hash chain on its next sync ([§7](#7-anti-rollback-the-account-head)).

## 11. Migration and backup plan

**Migrations:** one linear, append-only migration history, applied by whatever tool matches the
chosen stack ([§1](#1-server-stack)) — `wrangler d1 migrations` for (a), `golang-migrate`/`goose`
(Go) or a TS equivalent (e.g. Drizzle Kit) for (b)/(c)'s Postgres. Same discipline
`docs/adr/0003-vaultstore.md` already uses locally: an already-shipped migration is never edited,
only appended after. CI runs migrations against a scratch database as part of 851-2450's test
suite before they ever reach staging/prod.

**Backups**, independent of which stack wins:

- Point-in-time recovery, not just periodic full dumps — Postgres options (b)/(c) via WAL
  archiving (Fly Postgres backups, or Litestream to R2/S3); D1 (a) via its built-in "time travel"
  (30-day PITR) plus a scheduled export to R2 as an independent copy.
- **Backups live in a separate trust domain from the application's own credentials** — a bucket or
  account the application server cannot itself delete from — specifically so a fully compromised
  server (this ADR's own threat model, [§10](#10-threat-model-a-compromised-server)) can't also
  destroy the only way to recover from the compromise. This is a hard requirement regardless of
  which stack is chosen, not a nice-to-have.
- Because the server only ever stores ciphertext, a backup leak does not expose any vault content
  — but it must still be protected against *deletion*, both accidental and as extortion (an
  attacker deleting live data and backups to demand payment), which the separate-trust-domain
  requirement above addresses.
- **Restore drills, quarterly**: restore the latest backup into a scratch environment and confirm
  a real client can pull and decrypt against it end-to-end (using a disposable test account/vault
  key, never real user data) — verifying the backup is actually usable, not just that the database
  file opens. This is the same spirit as `docs/adr/0003-vaultstore.md`'s own emphasis on fail-fast,
  verifiable correctness over an untested assumption.

## Alternatives considered

- **Storing the vault key wrapped only under passkey PRF, with no recovery-key server login.**
  Rejected: PRF is web/macOS-15+-only (ADR 0002), so a Mac on the macOS 13 deployment target, or a
  first sync-enabled device in general, would have no way to establish the server-side wrapped-key
  blob in the first place without another path. The recovery key already exists and already
  authenticates "you own this vault" locally; reusing it server-side adds no new secret to manage.
- **JWTs for access tokens instead of opaque, looked-up tokens.** Rejected for this product
  specifically: immediate revocation ("this device is revoked, now") matters more here than
  avoiding one DB lookup per authenticated request, and this API's traffic volume doesn't come
  close to where that lookup would be a real cost.
- **A Merkle tree over all records instead of a linear hash chain for the account head.** Rejected
  as unneeded complexity: a Merkle tree's main advantage is efficient partial proofs ("prove record
  X is included without downloading everything else"), which this design doesn't need — a client
  always pulls its full missing range anyway, so a linear chain it can verify by replaying exactly
  the records it already received is simpler and equally effective at the one thing this ADR needs
  it for (detecting a rollback/fork), per [§7](#7-anti-rollback-the-account-head).
- **Server-side conflict resolution (merging fields instead of returning 409 + conflict copy).**
  Rejected: the server never has plaintext, so it cannot merge anything smarter than "whichever
  ciphertext arrived first wins the slot" — real merge logic has to happen client-side, where the
  plaintext is. This ADR's job is making sure the client has everything it needs to do that
  (the losing version, in full, in the 409 body), not attempting it server-side.

## Consequences

- 851-2450 can implement directly against `docs/api/sync.yaml` and this document's data model
  without further design work, other than the stack pick itself and the WebAuthn
  runtime-compatibility spike ([§1](#1-server-stack)).
- 851-2451 (Mac sync engine) has a stable `push`/`pull`/conflict/tombstone/head-verification
  contract to build its offline-first retry/backoff logic against, and a one-to-one field mapping
  from local `VaultRecord` to wire `SyncRecord` with no translation layer needed.
- 851-2452/851-2453 (web vault) can build passkey login and sync against the same API a Mac client
  uses — nothing in this design is Mac-specific.
- 851-2457 (device approval) has its full wire protocol specified here, including the
  account-key-pair provisioning question ADR 0002 left open ([§3](#3-account-key-pair-provisioning)).
- 851-2455 (third-party audit) has a concrete design document — including an explicit,
  non-hand-wavy threat model ([§10](#10-threat-model-a-compromised-server)) — to audit the eventual
  implementation against.
- Nothing here changes `VaultRecord`, `VaultCrypto`, or any shipped local code; this ADR is
  additive and can be revised without touching MVP behavior.

## Open questions for external review

- Is the account-head chain's per-record granularity ([§7](#7-anti-rollback-the-account-head)) the
  right unit, or should it batch per-push (one hash update per accepted request instead of per
  record) — coarser, cheaper, but slightly weaker (an attacker manipulating server-side ordering
  within a single accepted batch wouldn't be caught until the *next* batch, rather than
  immediately)?
- Is the manual short-code fallback in device approval ([§8](#8-device-approval-relay-851-2457))
  worth keeping at all, given its explicitly weaker assurance than QR scanning — or should the
  product simply require a camera/QR path and drop the fallback, accepting the accessibility cost?
- Should cross-device head comparison (a user-visible short account fingerprint, to close the
  "withheld updates a device has never seen" gap noted in [§7](#7-anti-rollback-the-account-head))
  be pulled into this milestone rather than deferred, given it's the one gap in the anti-rollback
  story that this design doesn't already close?
- Does `email` being fully optional (never required, never a login factor) create a support burden
  — e.g., no way to reach a user about a security-relevant event unless they opted in — that's
  worth trading against the "no unnecessary PII" goal?
