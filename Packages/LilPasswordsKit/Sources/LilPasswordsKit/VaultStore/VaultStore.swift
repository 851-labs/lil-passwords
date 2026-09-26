import Foundation

/// The SQLite-backed `VaultStoring` implementation: encrypted `PasswordItem` records persisted in
/// the app group's shared container, kept in sync with an in-memory decrypted index while
/// unlocked, and cross-process change notification via Darwin notifications.
///
/// See `docs/adr/0003-vaultstore.md` for the overall design (why the system `sqlite3` C API
/// rather than GRDB, the on-disk schema, the key-check canary, and how change observation works).
public actor VaultStore: VaultStoring {
  private let core: VaultStoreCore
  private let changeHub = VaultChangeHub()
  private let darwinNotificationName: String
  private var darwinObserver: DarwinNotificationObserver?

  /// The default database location: `~/Library/Application Support/Lil Passwords/vault.sqlite`,
  /// as the ticket specifies. Once the app-group container exists (851-2402/851-2427), the app
  /// and `LilPasswordsAgent` are expected to pass an app-group URL here instead — this default is
  /// only reached when no explicit `databaseURL` is given.
  public static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
    let appSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return
      appSupport
      .appendingPathComponent("Lil Passwords", isDirectory: true)
      .appendingPathComponent("vault.sqlite", isDirectory: false)
  }

  /// - Parameters:
  ///   - databaseURL: Where the SQLite database file lives. Defaults to
  ///     `defaultDatabaseURL()`. Tests should pass a URL inside a temporary directory instead, so
  ///     each test run gets its own isolated file.
  ///   - deviceId: This device's identity, recorded on every `VaultRecord` this store writes.
  ///     Defaults to a fresh random id; a real deployment (`LilPasswordsAgent`) is expected to
  ///     persist and reuse one id across launches, but nothing here requires that.
  ///   - darwinNotificationName: The Darwin notification name to post after a local write and
  ///     observe for external ones. Defaults to `DarwinNotifications.vaultChanged`, the name every
  ///     process is expected to agree on. Overridable so parallel tests don't cross-talk on this
  ///     system-wide, unscoped channel.
  public init(
    databaseURL: URL? = nil,
    deviceId: UUID = UUID(),
    darwinNotificationName: String? = nil
  ) throws {
    let url = try databaseURL ?? Self.defaultDatabaseURL()
    let storage = try SQLiteVaultRecordStorage(databaseURL: url)
    core = VaultStoreCore(storage: storage, deviceId: deviceId)
    self.darwinNotificationName = darwinNotificationName ?? DarwinNotifications.vaultChanged
  }

  // MARK: - Vault lifecycle

  @discardableResult
  public func createVault() throws -> VaultCrypto.RecoveryKey {
    let recoveryKey = try core.createVault()
    ensureDarwinObserver()
    notifyOfLocalChange()
    return recoveryKey
  }

  public func open(with key: VaultCrypto.Key) throws {
    try core.open(with: key)
    ensureDarwinObserver()
  }

  public func restoreKey(recoveryKey: VaultCrypto.RecoveryKey) throws -> VaultCrypto.Key {
    try core.restoreKey(recoveryKey: recoveryKey)
  }

  public func currentKey() throws -> VaultCrypto.Key {
    try core.currentKey()
  }

  public func vaultExists() throws -> Bool {
    try core.vaultExists()
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

  public func restore(id: UUID) throws {
    _ = try core.restore(id: id)
    notifyOfLocalChange()
  }

  public func deletePermanently(id: UUID) throws {
    _ = try core.deletePermanently(id: id)
    notifyOfLocalChange()
  }

  @discardableResult
  public func purgeExpired(now: Date) throws -> [UUID] {
    let purgedIds = try core.purgeExpired(now: now)
    if !purgedIds.isEmpty {
      notifyOfLocalChange()
    }
    return purgedIds
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

  /// Registers this instance's Darwin notification observer, if it hasn't been already. Called
  /// lazily from `createVault()`/`open(with:)` (rather than `init`) so the `[weak self]` capture
  /// below is only ever taken once the actor has finished initializing.
  private func ensureDarwinObserver() {
    guard darwinObserver == nil else { return }
    darwinObserver = DarwinNotificationObserver(name: darwinNotificationName) { [weak self] in
      guard let self else { return }
      Task { await self.handleExternalChange() }
    }
  }

  /// A write this instance itself just made: update local subscribers immediately (no Darwin
  /// roundtrip to wait on) and post the Darwin notification for every other process. This
  /// instance's own observer will also receive that post and call `handleExternalChange()`
  /// again — a harmless, redundant reload of a still-fresh index.
  private func notifyOfLocalChange() {
    Task { await changeHub.notify() }
    DarwinNotifications.post(darwinNotificationName)
  }

  /// A change this instance didn't necessarily make itself — either its own `notifyOfLocalChange`
  /// echo, or a genuine write from another process. Either way, reload the decrypted index (if
  /// unlocked; a no-op otherwise) and fan the signal out to subscribers.
  private func handleExternalChange() {
    if isUnlocked {
      try? core.reloadIndex()
    }
    Task { await changeHub.notify() }
  }
}
