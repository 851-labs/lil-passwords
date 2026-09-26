import Foundation
import Testing

@testable import LilPasswordsKit

private let testCaller = CallerIdentity(pid: 1, processPath: "/usr/local/bin/lilpass", parentProcessName: "zsh")

/// A distinctive value that would never otherwise appear on disk, so any test that finds it in the
/// log file has proven a real leak rather than a coincidental match.
private let secretPassword = "S3cr3t-Value-Should-Never-Be-Logged-9f3a"

/// A mutable "current time" a test can advance between `record(_:)` calls — plain `var` captures
/// aren't allowed in the `@Sendable` `now` closure `AccessLogStore` takes, so this boxes one behind
/// a lock-free actor instead.
private final class MutableClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date

  init(_ date: Date) { self.date = date }

  func advance(by interval: TimeInterval) {
    lock.lock()
    date = date.addingTimeInterval(interval)
    lock.unlock()
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return date
  }
}

@Suite struct AccessLogStoreTests {
  /// Every test gets its own throwaway file under a fresh temp directory, so tests never touch a
  /// real user's Application Support directory and never see each other's entries.
  private func makeStore(
    retention: TimeInterval = AccessLogStore.defaultRetention,
    now: @escaping @Sendable () -> Date = { Date() }
  ) throws -> (store: AccessLogStore, fileURL: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("access-log.jsonl", isDirectory: false)
    let store = try AccessLogStore(fileURL: fileURL, retention: retention, now: now)
    return (store, fileURL)
  }

  private func makeItem(title: String = "GitHub", password: String = "hunter2") -> PasswordItem {
    PasswordItem(
      title: title,
      usernames: ["octocat"],
      password: password,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  // MARK: - Writes and reads

  @Test func recordAppendsAnEntryThatFetchAllCanReadBack() async throws {
    let (store, _) = try makeStore()
    #expect(await store.fetchAll().isEmpty)

    await store.record(AccessEvent(caller: testCaller, request: .list, response: .items([]), succeeded: true))

    let entries = await store.fetchAll()
    #expect(entries.count == 1)
    #expect(entries[0].operation == "list")
    #expect(entries[0].succeeded == true)
  }

  @Test func recordAppendsMultipleEntriesInOrder() async throws {
    let (store, _) = try makeStore()

    await store.record(AccessEvent(caller: testCaller, request: .list, response: .items([]), succeeded: true))
    await store.record(
      AccessEvent(caller: testCaller, request: .search(query: "git"), response: .items([]), succeeded: true))
    await store.record(
      AccessEvent(caller: testCaller, request: .getItem(.id(UUID())), response: nil, succeeded: false)
    )

    let entries = await store.fetchAll()
    #expect(entries.map(\.operation) == ["list", "search", "getItem"])
    #expect(entries[2].succeeded == false)
  }

  @Test func fetchAllSkipsAPartiallyWrittenTrailingLineInsteadOfFailing() async throws {
    let (store, fileURL) = try makeStore()
    await store.record(AccessEvent(caller: testCaller, request: .list, response: .items([]), succeeded: true))

    // Simulate a crash mid-append: a second, truncated line with no trailing newline and invalid JSON.
    let handle = try FileHandle(forWritingTo: fileURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"not\": \"valid".utf8))

    let entries = await store.fetchAll()
    #expect(entries.count == 1)
    #expect(entries[0].operation == "list")
  }

  // MARK: - Clearing

  @Test func clearEmptiesTheLog() async throws {
    let (store, _) = try makeStore()
    await store.record(AccessEvent(caller: testCaller, request: .list, response: .items([]), succeeded: true))
    #expect(await store.fetchAll().count == 1)

    try await store.clear()

    #expect(await store.fetchAll().isEmpty)
  }

  // MARK: - Permissions

  @Test func theLogFileAndItsDirectoryAreRestrictedToTheOwner() async throws {
    let (store, fileURL) = try makeStore()
    await store.record(AccessEvent(caller: testCaller, request: .list, response: .items([]), succeeded: true))

    let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)

    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.deletingLastPathComponent().path)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o700)
  }

  @Test func clearRestoresRestrictedPermissions() async throws {
    let (store, fileURL) = try makeStore()
    await store.record(AccessEvent(caller: testCaller, request: .list, response: .items([]), succeeded: true))

    try await store.clear()

    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)
  }

  // MARK: - Pruning

  @Test func pruneDropsEntriesOlderThanRetentionOnTheNextRecord() async throws {
    let day: TimeInterval = 24 * 60 * 60
    let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
    let (store, _) = try makeStore(retention: 30 * day, now: clock.now)

    // An entry recorded "today"... `AccessEvent.date` defaults to the real wall clock, which this
    // test's injected `now` (deliberately pinned far in the past) would never treat as "old", so
    // the event's own date has to be pinned to the same fake clock for pruning to be exercised at
    // all.
    await store.record(
      AccessEvent(date: clock.now(), caller: testCaller, request: .list, response: .items([]), succeeded: true)
    )
    #expect(await store.fetchAll().count == 1)

    // ...31 days later is past the 30-day retention window, so the *next* record's pruning pass
    // should drop it, leaving only the new entry behind.
    clock.advance(by: 31 * day)
    await store.record(
      AccessEvent(
        date: clock.now(),
        caller: testCaller,
        request: .search(query: "git"),
        response: .items([]),
        succeeded: true
      )
    )

    let entries = await store.fetchAll()
    #expect(entries.count == 1)
    #expect(entries[0].operation == "search")
  }

  @Test func pruneKeepsEntriesStillWithinTheRetentionWindow() async throws {
    let day: TimeInterval = 24 * 60 * 60
    let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
    let (store, _) = try makeStore(retention: 30 * day, now: clock.now)

    await store.record(
      AccessEvent(date: clock.now(), caller: testCaller, request: .list, response: .items([]), succeeded: true)
    )

    clock.advance(by: 29 * day)
    await store.record(
      AccessEvent(
        date: clock.now(),
        caller: testCaller,
        request: .search(query: "git"),
        response: .items([]),
        succeeded: true
      )
    )

    let entries = await store.fetchAll()
    #expect(entries.count == 2)
  }

  // MARK: - Secret values must never reach the log

  @Test func creatingAnItemNeverWritesItsPasswordToTheOnDiskLog() async throws {
    let (store, fileURL) = try makeStore()
    let item = makeItem(password: secretPassword)

    await store.record(
      AccessEvent(caller: testCaller, request: .createItem(item), response: .created(item), succeeded: true)
    )

    let rawBytes = try Data(contentsOf: fileURL)
    #expect(!rawBytes.contains(secretPassword))

    let entries = await store.fetchAll()
    #expect(entries.count == 1)
    #expect(entries[0].fields.contains("password"))  // field *name*, not the value
    #expect(!entries[0].fields.contains(secretPassword))
  }

  @Test func readingAnItemNeverWritesItsPasswordToTheOnDiskLog() async throws {
    let (store, fileURL) = try makeStore()
    let item = makeItem(password: secretPassword)

    await store.record(
      AccessEvent(caller: testCaller, request: .getItem(.id(item.id)), response: .item(item), succeeded: true)
    )

    let rawBytes = try Data(contentsOf: fileURL)
    #expect(!rawBytes.contains(secretPassword))
  }

  @Test func updatingAnItemNeverWritesItsPasswordToTheOnDiskLog() async throws {
    let (store, fileURL) = try makeStore()
    let item = makeItem(password: secretPassword)

    await store.record(
      AccessEvent(caller: testCaller, request: .updateItem(item), response: .updated(item), succeeded: true)
    )

    let rawBytes = try Data(contentsOf: fileURL)
    #expect(!rawBytes.contains(secretPassword))
  }

  @Test func generatingAPasswordNeverWritesTheGeneratedValueToTheOnDiskLog() async throws {
    let (store, fileURL) = try makeStore()

    await store.record(
      AccessEvent(
        caller: testCaller,
        request: .generatePassword(.appleStrong),
        response: .generatedPassword(secretPassword),
        succeeded: true
      )
    )

    let rawBytes = try Data(contentsOf: fileURL)
    #expect(!rawBytes.contains(secretPassword))

    let entries = await store.fetchAll()
    #expect(entries[0].operation == "generatePassword")
    #expect(entries[0].fields == ["password"])
  }

  @Test func listingItemsNeverWritesAnyItemsPasswordToTheOnDiskLog() async throws {
    let (store, fileURL) = try makeStore()
    let items = [makeItem(title: "One", password: secretPassword), makeItem(title: "Two", password: "other-secret")]

    await store.record(AccessEvent(caller: testCaller, request: .list, response: .items(items), succeeded: true))

    let rawBytes = try Data(contentsOf: fileURL)
    #expect(!rawBytes.contains(secretPassword))
    #expect(!rawBytes.contains("other-secret"))
  }
}

extension Data {
  /// Whether this data contains `string`'s UTF-8 bytes anywhere as a contiguous run — used to
  /// assert a secret value never appears in a raw on-disk file, independent of its JSON encoding.
  fileprivate func contains(_ string: String) -> Bool {
    guard let needle = string.data(using: .utf8), !needle.isEmpty else { return false }
    guard count >= needle.count else { return false }
    for start in 0...(count - needle.count) {
      if self[startIndex + start..<startIndex + start + needle.count] == needle { return true }
    }
    return false
  }
}
