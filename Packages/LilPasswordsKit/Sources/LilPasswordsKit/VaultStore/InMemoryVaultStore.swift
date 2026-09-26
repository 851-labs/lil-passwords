import Foundation

/// A `VaultStoring` implementation backed entirely by in-memory state — no SQLite database file,
/// no Darwin notifications, no cross-process anything. For unit tests and SwiftUI previews that
/// want a real, working vault (real crypto, real CRUD/version/change-log semantics, all shared
/// with `VaultStore` via `VaultStoreCore`) without touching disk or the system-wide Darwin
/// notification namespace.
///
/// `observeChanges()` still works exactly as documented — local writes still yield to every live
/// subscriber — since that's `VaultChangeHub`, not the Darwin transport. It's specifically the
/// *cross-process* half of change observation this type doesn't do, which is the right trade-off
/// for a single-process test.
public actor InMemoryVaultStore: VaultStoring {
  private let core: VaultStoreCore
  private let changeHub = VaultChangeHub()

  public init(deviceId: UUID = UUID()) {
    core = VaultStoreCore(storage: InMemoryVaultRecordStorage(), deviceId: deviceId)
  }

  // MARK: - Vault lifecycle

  @discardableResult
  public func createVault() throws -> VaultCrypto.RecoveryKey {
    let recoveryKey = try core.createVault()
    notifyOfLocalChange()
    return recoveryKey
  }

  public func open(with key: VaultCrypto.Key) throws {
    try core.open(with: key)
  }

  public func restoreKey(recoveryKey: VaultCrypto.RecoveryKey) throws -> VaultCrypto.Key {
    try core.restoreKey(recoveryKey: recoveryKey)
  }

  public func currentKey() throws -> VaultCrypto.Key {
    try core.currentKey()
  }

  public func lock() {
    core.lock()
  }

  public var isUnlocked: Bool { core.isUnlocked }

  // MARK: - CRUD

  public func create(_ item: PasswordItem) throws {
    _ = try core.create(item)
    notifyOfLocalChange()
  }

  public func update(_ item: PasswordItem) throws {
    _ = try core.update(item)
    notifyOfLocalChange()
  }

  public func delete(id: UUID) throws {
    _ = try core.delete(id: id)
    notifyOfLocalChange()
  }

  public func item(id: UUID) throws -> PasswordItem? {
    try core.item(id: id)
  }

  public func allItems() throws -> [PasswordItem] {
    try core.allItems()
  }

  public func items(matching query: String) throws -> [PasswordItem] {
    try core.items(matching: query)
  }

  // MARK: - Change log

  public func changes(since seq: Int64) throws -> [VaultChangeLogEntry] {
    try core.changes(since: seq)
  }

  // MARK: - Change observation

  public func observeChanges() async -> AsyncStream<Void> {
    await changeHub.makeStream()
  }

  private func notifyOfLocalChange() {
    Task { await changeHub.notify() }
  }
}
