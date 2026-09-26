import Foundation

/// `VaultRecordStorage`, backed by plain in-memory collections. No file, no SQLite — used by
/// `InMemoryVaultStore` for tests and UI previews that want a working vault without touching disk.
final class InMemoryVaultRecordStorage: VaultRecordStorage {
  private var meta: VaultMetaRow?
  private var records: [UUID: VaultRecord] = [:]
  private var changeLog: [VaultChangeLogEntry] = []
  private var nextSeq: Int64 = 1

  func ensureSchema() throws {
    // Nothing to create — the collections above are always ready.
  }

  func loadMeta() throws -> VaultMetaRow? {
    meta
  }

  func saveMeta(_ meta: VaultMetaRow) throws {
    self.meta = meta
  }

  func loadAllRecords() throws -> [VaultRecord] {
    Array(records.values)
  }

  func loadRecord(id: UUID) throws -> VaultRecord? {
    records[id]
  }

  func upsertRecord(_ record: VaultRecord) throws {
    records[record.id] = record
  }

  func appendChangeLogEntry(recordId: UUID, version: UInt64, at date: Date) throws -> VaultChangeLogEntry {
    let entry = VaultChangeLogEntry(seq: nextSeq, recordId: recordId, version: version)
    nextSeq += 1
    changeLog.append(entry)
    return entry
  }

  func changeLogEntries(since seq: Int64) throws -> [VaultChangeLogEntry] {
    changeLog.filter { $0.seq > seq }
  }
}
