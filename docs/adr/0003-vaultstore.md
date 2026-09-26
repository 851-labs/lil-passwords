# 0003. VaultStore: encrypted SQLite, CRUD, change observation

- Status: Accepted
- Related: [851-2404](https://linear.app/851/issue/851-2404) (this ticket), [851-2402](https://linear.app/851/issue/851-2402) (storage/process-model spike, `docs/adr/0001-storage-and-process-model.md`), [851-2446](https://linear.app/851/issue/851-2446) (crypto design, `docs/adr/0002-crypto.md`), [851-2403](https://linear.app/851/issue/851-2403) (`PasswordItem`/`VaultRecord`/`RecordCodec`), [851-2427](https://linear.app/851/issue/851-2427) (XPC, not yet built)

## Context

`VaultRecord`/`RecordCodec` (851-2403) already define the sync-ready envelope and how to seal/open one against a vault key. `VaultCrypto` (851-2446) already defines the vault key, recovery key, and wrap/unwrap. Neither is persisted anywhere yet — that's this ticket. `docs/adr/0001-storage-and-process-model.md` already decided *where* the database file lives and *how* processes learn about each other's writes; this ADR is about what's built on top of those decisions: the actual table schema, the store's CRUD/lifecycle API, and how change observation is wired up in code.

Per the project decisions, `LilPasswordsAgent` will be the process that actually owns a `VaultStore` instance and serves it to the app/`lilpass` over XPC — but that XPC layer is 851-2427, not this ticket. `VaultStore` itself must have zero knowledge of XPC, agents, or processes; it's a plain library type in `LilPasswordsKit` that could just as easily be embedded directly in a single-process test or a SwiftUI preview.

## Decision

### SQLite via the system C API, not GRDB

`VaultStore` talks to `libsqlite3` directly through `import SQLite3` (Swift's bundled system-library module map for it) rather than adding GRDB or another wrapper as a dependency.

- **No new dependency.** `import SQLite3` plus `linkerSettings: [.linkedLibrary("sqlite3")]` in `Package.swift` is enough — confirmed with a throwaway SPM executable target that opens a database, checks `sqlite3_libversion()`, and closes it again, with no external package resolution at all. GRDB is a fine library, but this project's MVP has exactly one, fairly narrow SQLite need (a handful of tables, no complex queries, no `Codable`-via-SQL magic), and the project already leans toward "no dependency" where the system frameworks cover it (see `VaultCrypto` choosing `CryptoKit` over a crypto package).
- **The surface this ticket needs is small.** Prepared statements, binds, steps, a transaction helper. `SQLiteDatabase`/`SQLiteStatement` (this ticket) are a few dozen lines each and are the only two files that ever see a raw `OpaquePointer`; everything above them (`SQLiteVaultRecordStorage`) works with Swift types.
- **The trade-off, acknowledged:** GRDB would have given us database observation (`ValueObservation`), a migrator, and safer statement building for free. We're deliberately not using any of that — change observation here is Darwin notifications (already decided in ADR 0001), migrations are a ~30-line hand-rolled runner (below), and every query in this file is static SQL with positional binds, not dynamic enough to benefit from a query builder. If `VaultStore`'s query needs grow substantially later (real joins, dynamic filters), revisit; nothing here should make swapping the storage backend behind `VaultRecordStorage` hard.

### Schema

One SQLite file, four tables, created by a migration runner (below):

```sql
CREATE TABLE meta (
  id INTEGER PRIMARY KEY CHECK (id = 1),  -- always exactly one row
  vaultId TEXT NOT NULL,                  -- UUID string
  formatVersion INTEGER NOT NULL,
  wrappedKeyJSON BLOB NOT NULL,           -- JSON-encoded VaultCrypto.WrappedKey
  keyCheckJSON BLOB NOT NULL,             -- JSON-encoded VaultCrypto.SealedItem (see "Key-check canary")
  createdAt REAL NOT NULL                 -- Unix timestamp
);

CREATE TABLE records (
  id TEXT PRIMARY KEY,                    -- UUID string, matches VaultRecord.id
  type TEXT NOT NULL,
  version INTEGER NOT NULL,
  modifiedAt REAL NOT NULL,
  deviceId TEXT NOT NULL,
  deleted INTEGER NOT NULL,               -- 0/1, VaultRecord.deleted (sync tombstone, not user delete)
  keyId TEXT NOT NULL,                    -- VaultCrypto.SealedItem.keyId
  formatVersion INTEGER NOT NULL,         -- VaultCrypto.SealedItem.formatVersion
  sealed BLOB NOT NULL,                   -- VaultCrypto.SealedItem.combined
  schemaVersion INTEGER NOT NULL
);

CREATE TABLE changes (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,  -- the sync cursor
  recordId TEXT NOT NULL,
  version INTEGER NOT NULL,
  at REAL NOT NULL
);
CREATE INDEX changes_recordId ON changes(recordId);

CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, appliedAt REAL NOT NULL);
```

`records` stores exactly the plaintext columns `VaultRecord` itself defines — nothing about a `PasswordItem`'s title, usernames, password, etc. ever appears outside `sealed`. `meta` is the vault's single-row header: identity, the wrapped vault key, and a key-check canary (below). `changes` is the append-only log the ticket asks for, so a future sync engine gets a stable `seq` cursor ("give me everything after the last `seq` I've seen") without re-scanning `records` or inferring order from `modifiedAt` (which is wall-clock, not a cursor — two records can share a timestamp, but never a `seq`).

### Migrations table *and* `PRAGMA user_version`, both

The ticket asks for both, deliberately: `schema_migrations` records *when* each version was applied (useful for debugging a user's vault file — "what build last touched this schema"), while `PRAGMA user_version` is what a plain `sqlite3`/DB Browser session can check with zero query against this project's own tables. `SQLiteVaultRecordStorage.ensureSchema()` runs any migration whose `version` is greater than the highest recorded one, each inside its own `BEGIN IMMEDIATE` transaction (schema statements + the `schema_migrations` insert atomically), then sets `PRAGMA user_version` to match. Migrations are an append-only array (`Migration(version:statements:)`); an already-shipped entry is never edited, only appended after.

### Key-check canary, for fast wrong-key detection

`open(with:)` needs to answer "is this the right key?" fast and cleanly — including for a brand-new vault with zero records, where there's nothing to try decrypting. `createVault()` seals a fixed plaintext (`"com.851labs.lilpasswords.vault-key-check"`) under the new vault key, with a dedicated `VaultCrypto.AAD` (`type: "vault-key-check"`, `recordId` the vault's own id), and stores the result in `meta.keyCheckJSON`. `open(with:)` tries to open that canary before trusting the candidate key at all; a failure maps to `VaultStoreError.incorrectKey` rather than the raw `VaultCrypto.Error.authenticationFailed`, and no real record needs to exist for this check to work.

### CRUD, versions, and soft delete

Every write goes through `RecordCodec.seal`, which folds the row's `version` into the AAD (851-2403's replay-protection follow-up) — `VaultStoreCore` is responsible for picking the right next `version` (`existing.version + 1`, or `1` for a brand-new row) and re-sealing the *entire* current `PasswordItem` each time, not a partial patch; SQLite rows are opaque ciphertext, there's no column-level update to a sealed blob.

`delete(id:)` is a **user-facing soft delete**: it sets `PasswordItem.deletedAt` (if not already set) and writes that through as an ordinary version bump — the item is still fully present, still decryptable, still returned by `allItems()`/`item(id:)`, just flagged as being in "Recently Deleted." It deliberately does **not** set `VaultRecord.deleted`, which is a different, sync-layer concept: the tombstone marking that a row's *content* has been purged entirely (see `VaultRecord.deleted`'s doc comment). Nothing in this ticket's scope purges content or sets that flag — it's reserved for a future retention/purge operation once a UI decides "Recently Deleted" items are old enough to actually erase.

### The decrypted in-memory index and `items(matching:)`

`VaultStoreCore` keeps every non-tombstoned record's decrypted `PasswordItem` in a `[UUID: PasswordItem]` dictionary while unlocked, rebuilt (`reloadIndex()`) on `open(with:)`, `createVault()`, and whenever the store learns of an externally-made change (below). `allItems()`, `item(id:)`, and `items(matching:)` all read from this index rather than decrypting per call — the ticket's "search over a decrypted in-memory index while unlocked" requirement. `items(matching:)` does a case-insensitive substring match over title, usernames, and website hosts; an empty/whitespace-only query returns everything, same as `allItems()`.

`reloadIndex()` is deliberately fail-fast: if any non-tombstoned record fails to decrypt (wrong key — shouldn't happen once past the key-check canary — or a tampered/corrupted row), the *whole* reload throws rather than silently omitting that one item. A vault caught in a state it can't fully trust should surface that loudly, not quietly show a partial, possibly-stale view.

### Change observation: `AsyncStream` plus Darwin notifications

`observeChanges()` returns a fresh `AsyncStream<Void>` per call, fanned out by a small dedicated `actor VaultChangeHub` (rather than storing continuations directly on `VaultStore`) so an `AsyncStream.Continuation.onTermination` handler — which the runtime can invoke on an arbitrary thread when a subscriber's task is cancelled — always has a safe, actor-isolated place to remove itself from, instead of touching `VaultStore`'s own state from an unstructured context.

Every local write (`create`/`update`/`delete`/`createVault`) does two things: notifies `VaultChangeHub` directly (guaranteed, in-process delivery, no roundtrip to wait on) and posts the Darwin notification `com.851labs.lilpasswords.vaultChanged` from ADR 0001, for every *other* process. This instance's own Darwin observer also receives that post and reloads again — a harmless, redundant no-op reload of an already-fresh index, accepted as a simpler trade-off than trying to suppress self-notifications. Reloads triggered by an externally-observed change swallow decryption errors (`try?`) rather than crashing the observer callback; a real regression here is still caught by `open(with:)`'s own fail-fast reload and by the tamper-detection test below; this path only exists to keep a long-lived process's index fresh in the common case.

The Darwin observer is registered lazily (`ensureDarwinObserver()`, called from `createVault()`/`open(with:)`, not `init`), so its `[weak self]` capture is only ever taken once the actor has finished initializing — registering inside `init` would risk capturing `self` before it's fully constructed.

`VaultStore.init` accepts an optional `darwinNotificationName` override (default: the real, project-wide name) specifically so tests can each use a unique name — the Darwin notify center is a single, system-wide, unscoped namespace, and parallel test runs sharing the real name would cross-talk.

### `InMemoryVaultStore`, for tests and previews

`VaultStoreCore` — all vault-lifecycle and CRUD logic — is a plain, non-actor, synchronous class parameterized over a `VaultRecordStorage` protocol (`ensureSchema`/`loadMeta`/`saveMeta`/`loadAllRecords`/`loadRecord`/`upsertRecord`/`appendChangeLogEntry`/`changeLogEntries`). `VaultStore` (public actor, `SQLiteVaultRecordStorage`) and `InMemoryVaultStore` (public actor, `InMemoryVaultRecordStorage` — plain dictionaries/arrays, no file) both just hold one `VaultStoreCore` and delegate every protocol method to it, plus their own `VaultChangeHub` for `observeChanges()`. This means the two conformers share one implementation of "what does create/update/delete/open actually do" — the risk this ticket is most worried about is the SQLite-backed store and an in-memory test double quietly drifting apart, and sharing `VaultStoreCore` makes that structurally impossible rather than a matter of test discipline. `InMemoryVaultStore` skips Darwin notifications entirely (there's no second process to tell), but its `observeChanges()` still fires on local writes via its own `VaultChangeHub`, so it's a drop-in `VaultStoring` for a SwiftUI preview or a unit test that wants real CRUD/version/change-log semantics without touching disk.

Neither `VaultStoreCore` nor `VaultRecordStorage` is `public` — `VaultStoring` (the public protocol both actors conform to), `VaultStore`, `InMemoryVaultStore`, `VaultChangeLogEntry`, and `VaultStoreError` are the entire public surface this ticket adds.

### Why this is safe without extra locking

`VaultStoreCore`'s methods are all synchronous — none of them `await` anything internally. Both `VaultStore` and `InMemoryVaultStore` are actors that only ever call into their `VaultStoreCore` from within their own isolated methods, so actor isolation alone serializes every call; nothing here needs an additional lock or queue. The one place genuine cross-process contention is possible — two separate `VaultStore` instances (in two different processes, or, as this ticket's test does, two instances in one process) writing to the *same* SQLite file at the same time — is handled by `SQLiteDatabase.withTransaction`'s `BEGIN IMMEDIATE` (acquires the write lock up front, so a multi-statement write can't fail partway through already having made some of its changes) plus a 5-second `sqlite3_busy_timeout` (a losing writer retries briefly instead of immediately surfacing `SQLITE_BUSY`).

## Testing

`VaultStoringSharedBehaviorTests` holds plain `async throws` helper functions (CRUD lifecycle, locked-state errors, search, change-log ordering, local change observation) exercised identically against both `VaultStore` and `InMemoryVaultStore`, so a bug in the shared `VaultStoreCore` logic fails in both suites rather than only the one someone happened to test by hand. `VaultStoreTests` additionally covers what's specific to the SQLite backend: persistence across closing and reopening the same database file, wrong-key and tampered-record detection (the latter by corrupting a row's `sealed` blob directly via `SQLiteDatabase`/`SQLiteStatement`, bypassing `VaultStore` entirely, then confirming `open(with:)` fails rather than silently misreading it), recovery-key restore (success and failure), concurrent writes from two separate `VaultStore` instances against the same file, and a cross-instance Darwin-notification test (one instance writes, a second instance observing the same database via `observeChanges()` sees it, racing against a bounded timeout rather than an unconditional `await` so a regression here fails one test instead of hanging the whole suite).

## Consequences

- 851-2427 (XPC) can build `LilPasswordsAgent`'s XPC service directly on top of `VaultStoring` — it needs no changes to this ticket's public API, since `VaultStore` was written with zero XPC/agent-specific knowledge from the start.
- A future sync engine can use `changes(since:)`'s `seq` cursor to push/pull without migrating `records` or re-deriving order from `modifiedAt`.
- Vault key rotation (designed in ADR 0002, not built) would need a new `VaultStoreCore` method that re-seals every row under a new key — `SealedItem.keyId` already travels with each row, so that can proceed incrementally, matching ADR 0002's rotation design.
- Should `VaultStore`'s query needs grow beyond what hand-rolled SQL comfortably covers, `VaultRecordStorage` is the seam a GRDB-backed (or other) implementation would replace — `VaultStoreCore` and everything above it would be unaffected.
