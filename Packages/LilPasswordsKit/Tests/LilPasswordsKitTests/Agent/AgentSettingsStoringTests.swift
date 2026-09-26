import Foundation
import Security
import Testing

@testable import LilPasswordsKit

@Suite struct AgentSettingsStoringTests {
  // MARK: - InMemoryAgentSettingsStore

  @Test func loadReturnsNilWhenNothingHasEverBeenStored() throws {
    let store = InMemoryAgentSettingsStore()
    #expect(try store.load() == nil)
  }

  @Test func storeThenLoadRoundTrips() throws {
    let store = InMemoryAgentSettingsStore()
    let settings = AgentSettings(agentAccessEnabled: true, keepAgentAccessAvailableWhileMacUnlocked: true)
    try store.store(settings)
    #expect(try store.load() == settings)
  }

  @Test func storeReplacesAPreviouslyStoredValueRatherThanFailing() throws {
    let store = InMemoryAgentSettingsStore()
    try store.store(AgentSettings(agentAccessEnabled: true, keepAgentAccessAvailableWhileMacUnlocked: false))
    let replacement = AgentSettings(agentAccessEnabled: false, keepAgentAccessAvailableWhileMacUnlocked: true)
    try store.store(replacement)
    #expect(try store.load() == replacement)
  }

  @Test func loadThrowsWhenConstructedWithALoadError() {
    struct BoomError: Error, Equatable {}
    let store = InMemoryAgentSettingsStore(loadError: BoomError())
    #expect(throws: BoomError()) { try store.load() }
  }

  // MARK: - AgentSettings.loaded(from:) — the shared fail-closed helper

  @Test func loadedFromReturnsDisabledWhenNothingHasEverBeenStored() {
    let store = InMemoryAgentSettingsStore()
    #expect(AgentSettings.loaded(from: store) == .disabled)
  }

  @Test func loadedFromReturnsDisabledWhenTheStoreThrows() {
    struct BoomError: Error {}
    let store = InMemoryAgentSettingsStore(loadError: BoomError())
    #expect(AgentSettings.loaded(from: store) == .disabled)
  }

  @Test func loadedFromReturnsTheStoredValueWhenPresent() {
    let store = InMemoryAgentSettingsStore(
      initial: AgentSettings(agentAccessEnabled: true, keepAgentAccessAvailableWhileMacUnlocked: true)
    )
    #expect(
      AgentSettings.loaded(from: store)
        == AgentSettings(agentAccessEnabled: true, keepAgentAccessAvailableWhileMacUnlocked: true)
    )
  }

  // MARK: - KeychainAgentSettingsStore
  //
  // Exercises the real legacy Keychain, scoped to a per-test-run-unique service/account pair (like
  // `KeychainVaultKeyStoreTests`'s own pattern, if one exists) so parallel test runs on the same
  // machine can't collide, and cleans up after itself so a failed run doesn't leave a stray item
  // behind for the next one to trip over.

  private func makeKeychainStore() -> KeychainAgentSettingsStore {
    let unique = UUID().uuidString
    return KeychainAgentSettingsStore(
      service: "com.851labs.lilpasswords.tests.agentsettings.\(unique)",
      account: "agentSettings"
    )
  }

  @Test func keychainStoreLoadReturnsNilWhenNothingHasEverBeenStored() throws {
    let store = makeKeychainStore()
    #expect(try store.load() == nil)
  }

  @Test func keychainStoreRoundTripsAStoredValue() throws {
    let store = makeKeychainStore()
    let settings = AgentSettings(agentAccessEnabled: true, keepAgentAccessAvailableWhileMacUnlocked: true)
    try store.store(settings)
    defer { try? store.store(.disabled) }
    #expect(try store.load() == settings)
  }

  @Test func keychainStoreReplacesAPreviouslyStoredValue() throws {
    let store = makeKeychainStore()
    try store.store(AgentSettings(agentAccessEnabled: true, keepAgentAccessAvailableWhileMacUnlocked: false))
    let replacement = AgentSettings(agentAccessEnabled: false, keepAgentAccessAvailableWhileMacUnlocked: true)
    try store.store(replacement)
    defer { try? store.store(.disabled) }
    #expect(try store.load() == replacement)
  }
}
