import Foundation

/// One entry in a vault's append-only change log: "`recordId` moved to `version` at `seq`".
///
/// `VaultStore` writes one of these every time `create`/`update`/`delete` changes a record,
/// independent of `VaultRecord` itself. No sync engine exists yet (the MVP is fully local — see
/// the project's decisions), but `seq` gives a future one a stable, monotonically increasing
/// cursor to push and pull from without re-scanning the whole `records` table: "give me every
/// change after the last `seq` I've seen".
///
/// This is deliberately not the same thing as `VaultRecord.version` alone — two different
/// records can (and usually do) both be at `version: 1`, but their change-log entries still sort
/// unambiguously by `seq`, which is what a sync cursor actually needs.
public struct VaultChangeLogEntry: Sendable, Equatable {
  /// Strictly increasing within a single vault database. Never reused, even across process
  /// restarts, because it's backed by SQLite's `AUTOINCREMENT` rowid.
  public let seq: Int64

  /// Which record changed. Matches `VaultRecord.id`/`PasswordItem.id`.
  public let recordId: UUID

  /// The record's revision counter after this change (`VaultRecord.version`).
  public let version: UInt64

  public init(seq: Int64, recordId: UUID, version: UInt64) {
    self.seq = seq
    self.recordId = recordId
    self.version = version
  }
}
