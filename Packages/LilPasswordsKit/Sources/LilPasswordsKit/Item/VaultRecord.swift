import Foundation

/// The sync-ready envelope a `PasswordItem` (or, later, another item type) is stored as.
///
/// Deliberately minimal and free of anything user-visible: `title`, `websites`, `notes`, and
/// every other plaintext field of the sealed item live only inside `sealed`. Everything on
/// `VaultRecord` itself is metadata a sync server is allowed to see once one exists (per
/// `docs/adr/0002-crypto.md`'s "what a compromised server can learn"), and everything
/// `VaultStore` needs to answer "what changed, and in what order" without decrypting anything:
///
/// - `id`/`type`/`version`/`modifiedAt`/`deviceId` describe *this* row without revealing its
///   contents.
/// - `deleted` is a tombstone: sync propagates deletes as a flag on an otherwise-empty record,
///   not by removing rows outright, so a device that was offline during the delete still learns
///   about it. This is independent of `PasswordItem.deletedAt` — see that property's docs.
/// - `sealed` and `schemaVersion` are what `RecordCodec` needs to actually open the record.
///
/// No sync layer exists yet (the MVP is fully local — see the project's decisions), but every
/// field here is designed so one can be added later without migrating existing records.
public struct VaultRecord: Sendable, Equatable, Codable {
  /// The kind of item a record's `sealed` payload decodes to. A flat string-backed enum (rather
  /// than, say, relying on Swift's type system alone) because `type` also travels into
  /// `VaultCrypto.AAD`, which needs a stable wire value.
  public enum RecordType: String, Sendable, Equatable, Codable, CaseIterable {
    case passwordItem = "password-item"
  }

  /// Matches the sealed item's own `id` (e.g. `PasswordItem.id`). Also serves as `VaultCrypto.AAD.recordId`.
  public var id: UUID

  /// The kind of item this record holds.
  public var type: RecordType

  /// A per-record revision counter, incremented on every change. Two devices can compare
  /// `version`s to resolve conflicts without a central clock, and — as of 851-2403 — `version`
  /// is folded into the seal's authenticated data (`VaultCrypto.AAD.version`), so an old sealed
  /// revision can't be replayed back over a newer one. See "AAD includes the record version" in
  /// `docs/adr/0002-crypto.md`.
  public var version: UInt64

  /// When this revision was written, in the writer's clock. Plaintext (not part of `sealed`) so
  /// a sync client can order and merge records without decrypting anything.
  public var modifiedAt: Date

  /// Which device wrote this revision. Plaintext for the same reason as `modifiedAt`: conflict
  /// resolution and audit shouldn't require decryption.
  public var deviceId: UUID

  /// Whether this record has been tombstoned: its content has been purged and this row exists
  /// only to tell other devices "this id was deleted, stop syncing it". Distinct from
  /// `PasswordItem.deletedAt` — see that property's docs for how the two relate.
  public var deleted: Bool

  /// The encrypted payload: which vault key sealed it (`keyId`) and the AES-GCM output
  /// (`combined`). Opened via `RecordCodec.open`, which reconstructs the same `VaultCrypto.AAD`
  /// this record was sealed with from its own plaintext fields.
  public var sealed: VaultCrypto.SealedItem

  /// Which version of the item's Codable schema `sealed`'s plaintext was encoded with. Kept in
  /// the clear (rather than only inside the ciphertext) so a reader can pick the right decoder
  /// — and the right `VaultCrypto.AAD` to authenticate against — before attempting to open it.
  /// See `PasswordItemSchema`.
  public var schemaVersion: UInt32

  public init(
    id: UUID,
    type: RecordType,
    version: UInt64,
    modifiedAt: Date,
    deviceId: UUID,
    deleted: Bool,
    sealed: VaultCrypto.SealedItem,
    schemaVersion: UInt32
  ) {
    self.id = id
    self.type = type
    self.version = version
    self.modifiedAt = modifiedAt
    self.deviceId = deviceId
    self.deleted = deleted
    self.sealed = sealed
    self.schemaVersion = schemaVersion
  }
}
