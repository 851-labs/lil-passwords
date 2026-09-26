import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct InMemoryVaultStoreSharedBehaviorTests {
  @Test func lockedStateThrows() async throws {
    try await VaultStoringSharedBehavior.assertLockedStateThrows(InMemoryVaultStore())
  }

  @Test func crudLifecycle() async throws {
    try await VaultStoringSharedBehavior.assertCRUDLifecycle(InMemoryVaultStore())
  }

  @Test func search() async throws {
    try await VaultStoringSharedBehavior.assertSearch(InMemoryVaultStore())
  }

  @Test func restore() async throws {
    try await VaultStoringSharedBehavior.assertRestore(InMemoryVaultStore())
  }

  @Test func deletePermanently() async throws {
    try await VaultStoringSharedBehavior.assertDeletePermanently(InMemoryVaultStore())
  }

  @Test func purgeExpired() async throws {
    try await VaultStoringSharedBehavior.assertPurgeExpired(InMemoryVaultStore())
  }

  @Test func restoreAndDeletePermanentlyAndPurgeExpiredSignalChangeObservers() async throws {
    try await VaultStoringSharedBehavior.assertRestoreAndDeletePermanentlyAndPurgeExpiredSignalChangeObservers(
      InMemoryVaultStore()
    )
  }

  @Test func changeLogOrdering() async throws {
    try await VaultStoringSharedBehavior.assertChangeLogOrdering(InMemoryVaultStore())
  }

  @Test func localWritesSignalChangeObservers() async throws {
    try await VaultStoringSharedBehavior.assertLocalWritesSignalChangeObservers(InMemoryVaultStore())
  }
}

@Suite struct InMemoryVaultStoreTests {
  @Test func createVaultReturnsARecoveryKeyAndUnlocksTheStore() async throws {
    let store = InMemoryVaultStore()
    let recoveryKey = try await store.createVault()

    #expect(await store.isUnlocked)
    #expect(recoveryKey.entropy.count == VaultCrypto.RecoveryKey.byteCount)
  }

  @Test func createVaultTwiceFails() async throws {
    let store = InMemoryVaultStore()
    _ = try await store.createVault()

    await #expect(throws: VaultStoreError.vaultAlreadyExists) {
      _ = try await store.createVault()
    }
  }

  @Test func openingAVaultThatDoesNotExistFails() async throws {
    let store = InMemoryVaultStore()

    await #expect(throws: VaultStoreError.vaultNotFound) {
      try await store.open(with: .generate())
    }
  }

  @Test func openFailsWithTheWrongKey() async throws {
    let store = InMemoryVaultStore()
    _ = try await store.createVault()
    await store.lock()

    await #expect(throws: VaultStoreError.incorrectKey) {
      try await store.open(with: .generate())
    }
  }

  @Test func lockDropsTheKeyAndTheDecryptedIndex() async throws {
    let store = InMemoryVaultStore()
    _ = try await store.createVault()
    try await store.create(makeSamplePasswordItem())

    await store.lock()

    #expect(await store.isUnlocked == false)
    await #expect(throws: VaultStoreError.locked) {
      _ = try await store.allItems()
    }
  }

  @Test func restoreKeyRecoversTheVaultKeyAndCanReopenTheStore() async throws {
    let store = InMemoryVaultStore()
    let recoveryKey = try await store.createVault()
    let originalKey = try await store.currentKey()
    await store.lock()

    let restoredKey = try await store.restoreKey(recoveryKey: recoveryKey)
    #expect(restoredKey == originalKey)

    try await store.open(with: restoredKey)
    #expect(await store.isUnlocked)
  }

  @Test func restoreKeyFailsWithTheWrongRecoveryKey() async throws {
    let store = InMemoryVaultStore()
    _ = try await store.createVault()

    await #expect(throws: VaultStoreError.incorrectKey) {
      _ = try await store.restoreKey(recoveryKey: .generate())
    }
  }

  @Test func currentKeyFailsWhenLocked() async throws {
    let store = InMemoryVaultStore()

    await #expect(throws: VaultStoreError.locked) {
      _ = try await store.currentKey()
    }
  }

  /// Every CRUD call is an `actor` method, so many concurrent calls into the same instance are
  /// automatically serialized by the actor rather than by any locking this package writes itself.
  /// This exercises that: 50 concurrent `create` calls, none racing with each other, should all
  /// succeed and each get its own, uniquely ordered change-log entry.
  @Test func concurrentCreatesOnASingleInstanceAllSucceed() async throws {
    let store = InMemoryVaultStore()
    _ = try await store.createVault()

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<50 {
        group.addTask { try await store.create(makeSamplePasswordItem(title: "Item \(index)")) }
      }
      try await group.waitForAll()
    }

    let items = try await store.allItems()
    #expect(items.count == 50)

    let changes = try await store.changes(since: 0)
    #expect(changes.count == 50)
    #expect(Set(changes.map(\.seq)).count == 50)
  }
}
