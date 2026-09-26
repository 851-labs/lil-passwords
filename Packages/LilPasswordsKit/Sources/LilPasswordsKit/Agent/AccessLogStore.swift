import Foundation

/// The real, 851-2429 access log: an append-only JSONL file in Application Support, pruned to the
/// last 30 days.
///
/// JSONL (one JSON object per line) rather than SQLite: `VaultStore` already needs the raw C
/// sqlite3 API for the encrypted vault itself (see `Package.swift`'s `linkedLibrary("sqlite3")`),
/// but the access log has none of the requirements that justified that choice there — no
/// encryption, no concurrent-writer locking beyond "one helper process appends", no queries beyond
/// "read it all, filter in memory" — so a plain line-delimited file avoids pulling that C API in a
/// second time for a much simpler job. It also degrades gracefully: a partial line from a crash
/// mid-append is just skipped by ``fetchAll()``'s line-by-line decode, rather than corrupting
/// anything before or after it the way a torn write to a single JSON array or a SQLite page could.
///
/// The app reads this same file directly, off the same path, rather than over XPC (this ticket's
/// description allows either) — one less reason to add a new operation to
/// `AgentProtocol.swift`/`AgentXPCProtocol.swift`, which matters right now specifically because
/// 851-2411 (lock/unlock) is concurrently editing both of those files. This relies on the same
/// non-sandboxed, same-user, POSIX-permissions trust model `vault.sqlite` already does (see
/// docs/adr/0001-storage-and-process-model.md): anything that can read one of the app's own files
/// as the logged-in user could read the other too.
public actor AccessLogStore: AccessLogging {
  private let fileURL: URL
  private let fileManager: FileManager
  private let retention: TimeInterval
  private let now: @Sendable () -> Date

  /// How long entries are kept before ``record(_:)``'s automatic pruning drops them — 30 days,
  /// per this ticket.
  public static let defaultRetention: TimeInterval = 30 * 24 * 60 * 60

  /// - Parameters:
  ///   - fileURL: Defaults to ``defaultFileURL(fileManager:)`` — override in tests to avoid
  ///     touching a real user's Application Support directory.
  ///   - retention: Defaults to ``defaultRetention``. Overridable in tests so pruning can be
  ///     exercised without waiting 30 real days.
  ///   - now: Defaults to `Date.init`. Overridable in tests for the same reason.
  public init(
    fileURL: URL? = nil,
    fileManager: FileManager = .default,
    retention: TimeInterval = AccessLogStore.defaultRetention,
    now: @escaping @Sendable () -> Date = { Date() }
  ) throws {
    self.fileURL = try fileURL ?? Self.defaultFileURL(fileManager: fileManager)
    self.fileManager = fileManager
    self.retention = retention
    self.now = now
    try Self.ensureDirectoryExists(for: self.fileURL, fileManager: fileManager)
  }

  /// `~/Library/Application Support/lil passwords/access-log.jsonl` — the same directory
  /// `VaultStore.defaultDatabaseURL()` uses, so both land under one already-`0700` directory.
  public static func defaultFileURL(fileManager: FileManager = .default) throws -> URL {
    let appSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return
      appSupport
      .appendingPathComponent("lil passwords", isDirectory: true)
      .appendingPathComponent("access-log.jsonl", isDirectory: false)
  }

  // MARK: - AccessLogging

  public func record(_ event: AccessEvent) async {
    let entry = AccessEventSummary.entry(for: event)
    do {
      try append(entry)
      try prune(now: now())
    } catch {
      // The access log is a best-effort audit trail, not load-bearing for vault operations
      // themselves — a disk-full or permissions error here must never surface as a vault failure
      // to the caller (`AgentServer` doesn't even look at this method's return value), so this
      // reports to stderr for a developer to notice and otherwise swallows the error.
      FileHandle.standardError.write(Data("AccessLogStore: failed to record entry: \(error)\n".utf8))
    }
  }

  // MARK: - Reading and clearing (the Settings → Agents pane)

  /// Every entry currently on disk, oldest first. A line that fails to decode (a partial write
  /// from a crash mid-append, or a future/older format this build doesn't understand) is skipped
  /// rather than failing the whole read.
  public func fetchAll() -> [AccessLogEntry] {
    guard let data = try? Data(contentsOf: fileURL) else { return [] }
    return
      data
      .split(separator: UInt8(ascii: "\n"))
      .compactMap { line in try? AgentWireCoding.decoder.decode(AccessLogEntry.self, from: Data(line)) }
  }

  /// Empties the log — the Settings → Agents pane's "Clear Log" button.
  public func clear() throws {
    try Data().write(to: fileURL, options: .atomic)
    try restrictPermissions()
  }

  // MARK: - Storage

  private func append(_ entry: AccessLogEntry) throws {
    var line = try AgentWireCoding.encoder.encode(entry)
    line.append(UInt8(ascii: "\n"))

    if fileManager.fileExists(atPath: fileURL.path) {
      let handle = try FileHandle(forWritingTo: fileURL)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: line)
    } else {
      try line.write(to: fileURL, options: .atomic)
      try restrictPermissions()
    }
  }

  /// Drops every entry older than `retention`, rewriting the file in place. Read-prune-rewrite
  /// rather than an in-place edit: JSONL has no efficient way to delete leading lines, and this
  /// file is small enough (one line per agent request, itself bounded to 30 days) that rewriting
  /// it wholesale on every write is cheap.
  private func prune(now: Date) throws {
    let cutoff = now.addingTimeInterval(-retention)
    let entries = fetchAll()
    guard entries.contains(where: { $0.date < cutoff }) else { return }

    let survivors = entries.filter { $0.date >= cutoff }
    var data = Data()
    for entry in survivors {
      data.append(try AgentWireCoding.encoder.encode(entry))
      data.append(UInt8(ascii: "\n"))
    }
    try data.write(to: fileURL, options: .atomic)
    try restrictPermissions()
  }

  /// Every access-log entry is, by construction (``AccessEventSummary``), free of secret values —
  /// but it's still a record of exactly which accounts an agent looked at and when, which is
  /// sensitive on its own terms. `0600` matches `vault.sqlite`'s own sidecar files
  /// (`SQLiteVaultRecordStorage.restrictSidecarFilePermissions`) and this ticket's explicit
  /// requirement.
  private func restrictPermissions() throws {
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  private static func ensureDirectoryExists(for fileURL: URL, fileManager: FileManager) throws {
    let directory = fileURL.deletingLastPathComponent()
    guard !fileManager.fileExists(atPath: directory.path) else { return }
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }
}
