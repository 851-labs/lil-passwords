import Foundation
import Testing

@testable import LilPasswordsKit

/// Behavior every `VaultStoring` conformer must get right, exercised identically against
/// `VaultStore` (SQLite-backed) and `InMemoryVaultStore` so the two never quietly drift apart —
/// both share `VaultStoreCore`, so a bug here is almost certainly a bug in that shared logic.
///
/// These are plain `async throws` functions, not `@Test`s themselves: each conforming store's own
/// test suite (`VaultStoreTests`, `InMemoryVaultStoreTests`) calls them from its own `@Test`
/// functions, so failures are still attributed to a specific, storage-specific test name.
enum VaultStoringSharedBehavior {
  static func assertLockedStateThrows(_ store: some VaultStoring) async throws {
    #expect(await store.isUnlocked == false)

    await #expect(throws: VaultStoreError.locked) {
      try await store.create(makeSamplePasswordItem())
    }
    await #expect(throws: VaultStoreError.locked) {
      _ = try await store.allItems()
    }
    await #expect(throws: VaultStoreError.locked) {
      _ = try await store.items(matching: "")
    }
    await #expect(throws: VaultStoreError.locked) {
      _ = try await store.item(id: UUID())
    }
  }

  static func assertCRUDLifecycle(_ store: some VaultStoring) async throws {
    _ = try await store.createVault()
    #expect(await store.isUnlocked)

    var item = makeSamplePasswordItem()
    try await store.create(item)

    let fetched = try await store.item(id: item.id)
    #expect(fetched == item)

    await #expect(throws: VaultStoreError.itemAlreadyExists(item.id)) {
      try await store.create(item)
    }

    item.title = "Updated Title"
    item.password = "correct-horse-battery-staple"
    try await store.update(item)

    let updated = try await store.item(id: item.id)
    #expect(updated?.title == "Updated Title")
    #expect(updated?.password == "correct-horse-battery-staple")

    let missingId = UUID()
    await #expect(throws: VaultStoreError.itemNotFound(missingId)) {
      try await store.update(PasswordItem(id: missingId, title: "Ghost"))
    }

    try await store.delete(id: item.id)
    let afterDelete = try await store.item(id: item.id)
    #expect(afterDelete?.deletedAt != nil)

    // Soft delete: the item is still present via `allItems()`/`item(id:)`, just flagged.
    let all = try await store.allItems()
    #expect(all.contains(where: { $0.id == item.id }))

    await #expect(throws: VaultStoreError.itemNotFound(missingId)) {
      try await store.delete(id: missingId)
    }

    let neverExisted = try await store.item(id: UUID())
    #expect(neverExisted == nil)
  }

  static func assertRestore(_ store: some VaultStoring) async throws {
    _ = try await store.createVault()

    let item = makeSamplePasswordItem()
    try await store.create(item)
    try await store.delete(id: item.id)
    #expect(try await store.item(id: item.id)?.deletedAt != nil)

    try await store.restore(id: item.id)
    let restored = try await store.item(id: item.id)
    #expect(restored?.deletedAt == nil)
    #expect(restored?.title == item.title)

    // Restoring an item that was never deleted is a harmless no-op on content.
    try await store.restore(id: item.id)
    #expect(try await store.item(id: item.id)?.deletedAt == nil)

    let missingId = UUID()
    await #expect(throws: VaultStoreError.itemNotFound(missingId)) {
      try await store.restore(id: missingId)
    }

    // Once permanently deleted, there's nothing left to restore.
    try await store.deletePermanently(id: item.id)
    await #expect(throws: VaultStoreError.itemNotFound(item.id)) {
      try await store.restore(id: item.id)
    }
  }

  static func assertDeletePermanently(_ store: some VaultStoring) async throws {
    _ = try await store.createVault()

    let item = makeSamplePasswordItem()
    try await store.create(item)
    try await store.delete(id: item.id)

    let changesBefore = try await store.changes(since: 0)
    try await store.deletePermanently(id: item.id)

    // Gone from the decrypted index entirely, not just flagged.
    let afterPurge = try await store.item(id: item.id)
    #expect(afterPurge == nil)
    let all = try await store.allItems()
    #expect(all.contains(where: { $0.id == item.id }) == false)

    // The change log still records the write, for a future sync engine.
    let changesAfter = try await store.changes(since: 0)
    #expect(changesAfter.count == changesBefore.count + 1)
    #expect(changesAfter.last?.recordId == item.id)

    // Already gone — a second permanent delete has nothing to act on.
    await #expect(throws: VaultStoreError.itemNotFound(item.id)) {
      try await store.deletePermanently(id: item.id)
    }

    let missingId = UUID()
    await #expect(throws: VaultStoreError.itemNotFound(missingId)) {
      try await store.deletePermanently(id: missingId)
    }

    // Permanently deleting an item that was never soft-deleted is allowed.
    let neverSoftDeleted = makeSamplePasswordItem(title: "Never soft-deleted")
    try await store.create(neverSoftDeleted)
    try await store.deletePermanently(id: neverSoftDeleted.id)
    #expect(try await store.item(id: neverSoftDeleted.id) == nil)
  }

  static func assertPurgeExpired(_ store: some VaultStoring) async throws {
    _ = try await store.createVault()

    let reference = Date()
    let fresh = makeSamplePasswordItem(title: "Fresh")
    let borderline = makeSamplePasswordItem(title: "Borderline")
    let expired = makeSamplePasswordItem(title: "Expired")
    let neverDeleted = makeSamplePasswordItem(title: "Never deleted")

    for item in [fresh, borderline, expired, neverDeleted] {
      try await store.create(item)
    }
    try await store.delete(id: fresh.id)
    try await store.delete(id: borderline.id)
    try await store.delete(id: expired.id)

    let retention = PasswordItem.recentlyDeletedRetentionPeriod

    // Nothing is old enough yet.
    let purgedNow = try await store.purgeExpired(now: reference)
    #expect(purgedNow.isEmpty)

    // Exactly at the retention boundary: "more than 30 days" hasn't happened yet.
    let purgedAtBoundary = try await store.purgeExpired(now: reference.addingTimeInterval(retention))
    #expect(purgedAtBoundary.isEmpty)

    // Just past the boundary: only the items actually deleted purge; a never-deleted item never
    // qualifies no matter how far `now` is pushed out.
    let purged = try await store.purgeExpired(now: reference.addingTimeInterval(retention + 5))
    #expect(Set(purged) == Set([fresh.id, borderline.id, expired.id]))

    #expect(try await store.item(id: fresh.id) == nil)
    #expect(try await store.item(id: borderline.id) == nil)
    #expect(try await store.item(id: expired.id) == nil)
    #expect(try await store.item(id: neverDeleted.id) != nil)

    // Already purged — running it again finds nothing left to do.
    let purgedAgain = try await store.purgeExpired(now: reference.addingTimeInterval(retention * 2))
    #expect(purgedAgain.isEmpty)
  }

  static func assertSearch(_ store: some VaultStoring) async throws {
    _ = try await store.createVault()

    let gitHub = makeSamplePasswordItem(
      title: "GitHub",
      usernames: ["octocat"],
      websites: [URL(string: "https://github.com/login")!]
    )
    let gmail = makeSamplePasswordItem(
      title: "Gmail",
      usernames: ["alice@example.com"],
      websites: [URL(string: "https://mail.google.com")!]
    )
    try await store.create(gitHub)
    try await store.create(gmail)

    let byTitle = try await store.items(matching: "git")
    #expect(byTitle.map(\.id) == [gitHub.id])

    let byUsername = try await store.items(matching: "OCTOCAT")
    #expect(byUsername.map(\.id) == [gitHub.id])

    let byHost = try await store.items(matching: "google")
    #expect(byHost.map(\.id) == [gmail.id])

    let noMatch = try await store.items(matching: "does-not-exist")
    #expect(noMatch.isEmpty)

    let empty = try await store.items(matching: "   ")
    #expect(Set(empty.map(\.id)) == Set([gitHub.id, gmail.id]))
  }

  static func assertChangeLogOrdering(_ store: some VaultStoring) async throws {
    _ = try await store.createVault()

    let items = (0..<5).map { index in makeSamplePasswordItem(title: "Item \(index)") }
    for item in items {
      try await store.create(item)
    }

    var updated = items[1]
    updated.title = "Changed"
    try await store.update(updated)

    let allChanges = try await store.changes(since: 0)
    #expect(allChanges.count == 6)
    #expect(allChanges.map(\.seq) == allChanges.map(\.seq).sorted())
    #expect(Set(allChanges.map(\.seq)).count == allChanges.count)
    #expect(allChanges.last?.recordId == updated.id)
    #expect(allChanges.last?.version == 2)

    let cursor = allChanges[2].seq
    let sincePartial = try await store.changes(since: cursor)
    #expect(sincePartial.count == allChanges.count - 3)
    #expect(sincePartial.allSatisfy { $0.seq > cursor })

    let sinceLatest = try await store.changes(since: allChanges.last!.seq)
    #expect(sinceLatest.isEmpty)
  }

  static func assertLocalWritesSignalChangeObservers(_ store: some VaultStoring) async throws {
    let stream = await store.observeChanges()

    async let sawCreate = waitForFirstElement(of: stream)
    _ = try await store.createVault()
    #expect(await sawCreate)

    let secondStream = await store.observeChanges()
    async let sawWrite = waitForFirstElement(of: secondStream)
    try await store.create(makeSamplePasswordItem())
    #expect(await sawWrite)
  }

  /// `restore`, `deletePermanently`, and `purgeExpired` (when it actually purges something) are
  /// writes just like `create`/`update`/`delete`, and should signal `observeChanges()` the same
  /// way — this is easy to get wrong by forgetting the `notifyOfLocalChange()` call each of
  /// `VaultStore`/`InMemoryVaultStore` is responsible for adding around its `VaultStoreCore` call.
  static func assertRestoreAndDeletePermanentlyAndPurgeExpiredSignalChangeObservers(
    _ store: some VaultStoring
  ) async throws {
    _ = try await store.createVault()
    let item = makeSamplePasswordItem()
    try await store.create(item)
    try await store.delete(id: item.id)

    let restoreStream = await store.observeChanges()
    async let sawRestore = waitForFirstElement(of: restoreStream)
    try await store.restore(id: item.id)
    #expect(await sawRestore)

    try await store.delete(id: item.id)

    let deleteStream = await store.observeChanges()
    async let sawDeletePermanently = waitForFirstElement(of: deleteStream)
    try await store.deletePermanently(id: item.id)
    #expect(await sawDeletePermanently)

    let second = makeSamplePasswordItem(title: "Second")
    try await store.create(second)
    try await store.delete(id: second.id)

    let purgeStream = await store.observeChanges()
    async let sawPurge = waitForFirstElement(of: purgeStream)
    let purged = try await store.purgeExpired(
      now: Date().addingTimeInterval(PasswordItem.recentlyDeletedRetentionPeriod + 5)
    )
    #expect(purged == [second.id])
    #expect(await sawPurge)
  }
}
