import Foundation
import Security

/// Where `LilPasswordsAgent` persists the vault key between launches, so restarting the helper
/// (or rebooting) doesn't force creating a brand-new vault.
///
/// The real conformer (`KeychainVaultKeyStore`) uses the **local, file-based (legacy) Keychain**
/// — deliberately not the Data Protection Keychain, and with no `.userPresence` access control on
/// the item itself — per docs/adr/0001-storage-and-process-model.md (b): device-owner
/// authentication happens once, in the app, via `LAContext`; by the time the app asks the helper
/// to unlock, that authentication has already happened, and the connection itself is already
/// authenticated via `AgentConnectionSecurity`'s code-signing requirement, so gating this
/// Keychain read a second time (behind its own Touch ID prompt) would be redundant and is exactly
/// what ADR 0001 decided against after the 851-2402 spike.
public protocol VaultKeyStoring: Sendable {
  /// Persists `key`, replacing any previously stored key.
  func store(_ key: VaultCrypto.Key) throws

  /// The persisted key, or `nil` if none has ever been stored (or it was deleted).
  func loadKey() throws -> VaultCrypto.Key?

  /// Removes the persisted key, if any. Not currently called by any flow in this repo — there's
  /// no vault-deletion ticket yet — but is the natural counterpart to `store(_:)`.
  func deleteKey() throws
}

/// Wire shape for the Keychain item's value data. `VaultCrypto.Key` itself isn't `Codable` —
/// deliberately so, since a general-purpose encoding would make it easy for some future call site
/// to serialize the raw key material by accident — so this file defines its own narrow, private
/// encoding instead.
private struct StoredVaultKey: Codable {
  var id: UUID
  var rawData: Data
}

/// Everything that can go wrong talking to the Keychain, as a typed error rather than a bare
/// `OSStatus` a caller has to look up.
public enum VaultKeyStoreError: Error, Sendable, Equatable {
  case keychain(status: OSStatus)
  case corruptStoredKey
}

/// The production `VaultKeyStoring`: one generic-password item in the local (file-based,
/// non-synced) Keychain — exactly the item `LilPasswordsAgent` alone is ever expected to read or
/// write. See docs/adr/0001-storage-and-process-model.md for why this project deliberately
/// targets the legacy keychain (`kSecUseDataProtectionKeychain: false`) with no entitlement.
public struct KeychainVaultKeyStore: VaultKeyStoring {
  private let service: String
  private let account: String

  public init(
    service: String = "com.851labs.lilpasswords.vaultkey",
    account: String = "vaultKey"
  ) {
    self.service = service
    self.account = account
  }

  public func store(_ key: VaultCrypto.Key) throws {
    let payload = try JSONEncoder().encode(StoredVaultKey(id: key.id, rawData: key.rawData))

    // `SecItemUpdate` on a query with a `kSecValueData` in the query itself doesn't do what one
    // might expect (it matches on the *old* value, not just service/account), so replace via
    // delete-then-add instead — this item changes at most once per vault's lifetime (creation),
    // so there's no meaningful race to worry about losing here.
    try deleteKey()

    var query = baseQuery()
    query[kSecValueData as String] = payload
    query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw VaultKeyStoreError.keychain(status: status)
    }
  }

  public func loadKey() throws -> VaultCrypto.Key? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status != errSecItemNotFound else { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw VaultKeyStoreError.keychain(status: status)
    }

    let stored: StoredVaultKey
    do {
      stored = try JSONDecoder().decode(StoredVaultKey.self, from: data)
    } catch {
      throw VaultKeyStoreError.corruptStoredKey
    }
    do {
      return try VaultCrypto.Key(id: stored.id, rawData: stored.rawData)
    } catch {
      throw VaultKeyStoreError.corruptStoredKey
    }
  }

  public func deleteKey() throws {
    let status = SecItemDelete(baseQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw VaultKeyStoreError.keychain(status: status)
    }
  }

  private func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      // The legacy, file-based Keychain, not the Data Protection Keychain — see this type's
      // documentation and docs/adr/0001-storage-and-process-model.md.
      kSecUseDataProtectionKeychain as String: false,
    ]
  }
}

/// An in-memory `VaultKeyStoring` for tests and the in-process XPC end-to-end harness — no real
/// Keychain access, so tests don't depend on (or pollute) the host machine's login keychain. A
/// plain lock-protected class rather than an actor: `VaultKeyStoring` itself is a synchronous,
/// non-async protocol (so `KeychainVaultKeyStore`, a plain struct, can conform without any actor
/// hop), and this conformer needs to match that.
public final class InMemoryVaultKeyStore: VaultKeyStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: VaultCrypto.Key?

  public init() {}

  public func store(_ key: VaultCrypto.Key) throws {
    lock.lock()
    defer { lock.unlock() }
    stored = key
  }

  public func loadKey() throws -> VaultCrypto.Key? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  public func deleteKey() throws {
    lock.lock()
    defer { lock.unlock() }
    stored = nil
  }
}
