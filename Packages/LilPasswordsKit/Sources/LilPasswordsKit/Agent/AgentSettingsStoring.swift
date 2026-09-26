import Foundation
import Security

/// Where `LilPasswordsAgent` persists the 851-2428 agent-access settings (``AgentSettings``)
/// between launches.
///
/// Deliberately **not** the shared `AppSettings` `UserDefaults` suite every other preference uses:
/// that suite is, by design, readable *and freely writable* by any local process that knows its
/// name (see `AppSettings`'s own documentation, and `defaults write
/// com.851labs.lilpasswords.shared ...`), which would let an agent silently flip its own access
/// back on the moment a user turned it off. These two settings need write access restricted to the
/// helper alone — see ``KeychainAgentSettingsStore`` and
/// docs/adr/0001-storage-and-process-model.md (e) for the full reasoning.
public protocol AgentSettingsStoring: Sendable {
  /// The persisted settings, or `nil` if none have ever been stored.
  ///
  /// Callers must **fail closed**: treat both `nil` and a thrown error the same way, as
  /// ``AgentSettings/disabled`` — never as "enabled". See ``AgentSettings/loaded(from:)``, the one
  /// place that flattening happens, shared by `AgentServer` and `AgentSettingsAccessPolicy` so
  /// neither can independently get the fallback wrong.
  func load() throws -> AgentSettings?

  /// Persists `settings`, replacing whatever was stored before.
  func store(_ settings: AgentSettings) throws
}

extension AgentSettings {
  /// Reads `store`, failing closed to ``disabled`` on any error (a corrupt item, an unreadable
  /// Keychain) or "nothing stored yet". The one place both `AgentServer` and
  /// `AgentSettingsAccessPolicy` derive "the current agent settings" from, so what counts as a safe
  /// fallback can't drift between the two call sites.
  public static func loaded(from store: any AgentSettingsStoring) -> AgentSettings {
    guard let loaded = try? store.load() else { return .disabled }
    return loaded ?? .disabled
  }
}

/// Everything that can go wrong talking to the Keychain on ``KeychainAgentSettingsStore``'s behalf,
/// as a typed error rather than a bare `OSStatus` a caller has to look up.
public enum AgentSettingsStoreError: Error, Sendable, Equatable {
  case keychain(status: OSStatus)
  case corruptStoredSettings
}

/// The production `AgentSettingsStoring`: one generic-password item in the local (file-based,
/// legacy) Keychain — see docs/adr/0001-storage-and-process-model.md (a) for why this project
/// targets the legacy Keychain rather than the Data Protection Keychain at all — but, unlike
/// ``KeychainVaultKeyStore``'s vault-key item (which relies on the legacy Keychain's *implicit*
/// default ACL restricting access to the creating app; see that ADR's section (b)), this item's ACL
/// is set **explicitly** via `SecAccessCreate`/`SecTrustedApplicationCreateFromPath`, naming this
/// process's own code identity as the item's *only* trusted application.
///
/// That explicit ACL is what closes the 851-2428 security review's second blocker: without it, the
/// item would still only be readable/writable by whichever app created it under the *implicit*
/// default ACL too — but making it explicit here means the trust decision is visible in this file
/// rather than relying on Keychain's unwritten default behavior, and it means a `security
/// add-generic-password`/`find-generic-password` (or any other local process) attempting to
/// overwrite or read this specific item is met with a Keychain access-control prompt rather than
/// silent success, the same way it would be for any other app's ACL'd item. See docs/adr/0001-storage-and-process-model.md
/// (e) for the full write-up, including why this — rather than sealing these settings in the
/// vault's own metadata — was chosen.
public struct KeychainAgentSettingsStore: AgentSettingsStoring {
  private let service: String
  private let account: String

  public init(
    service: String = "com.851labs.lilpasswords.agentsettings",
    account: String = "agentSettings"
  ) {
    self.service = service
    self.account = account
  }

  public func load() throws -> AgentSettings? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status != errSecItemNotFound else { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw AgentSettingsStoreError.keychain(status: status)
    }

    do {
      return try AgentWireCoding.decoder.decode(AgentSettings.self, from: data)
    } catch {
      throw AgentSettingsStoreError.corruptStoredSettings
    }
  }

  public func store(_ settings: AgentSettings) throws {
    let payload = try AgentWireCoding.encoder.encode(settings)

    // Same delete-then-add replace strategy as `KeychainVaultKeyStore.store(_:)` — `SecItemUpdate`
    // against a query containing `kSecValueData` doesn't behave as "replace the value" (see that
    // type's own comment) — and this item changes at most a couple of times per session (a user
    // flipping a Settings toggle), so there's no meaningful race to worry about losing here.
    try? deleteExisting()

    var query = baseQuery()
    query[kSecValueData as String] = payload
    query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    query[kSecAttrAccess as String] = try trustedAccess()
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw AgentSettingsStoreError.keychain(status: status)
    }
  }

  private func deleteExisting() throws {
    let status = SecItemDelete(baseQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw AgentSettingsStoreError.keychain(status: status)
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

  /// Builds a `SecAccess` trusting only this process's own code identity as the item's sole
  /// trusted application. `SecTrustedApplicationCreateFromPath(nil, _:)`'s `nil` path is documented
  /// to resolve to "the code calling this function" — i.e. `LilPasswordsAgent` itself, not a
  /// hardcoded path that could go stale across app moves/updates.
  ///
  /// Both APIs are deprecated in favor of the Data Protection Keychain's entitlement-based model,
  /// which this project doesn't use (see docs/adr/0001-storage-and-process-model.md (a)); they're
  /// still fully functional against the legacy Keychain, consistent with this codebase's existing
  /// reliance on other legacy/deprecated Security-framework APIs (`SecCodeCopyGuestWithAttributes`
  /// in `CallerIdentity.swift`, for one).
  private func trustedAccess() throws -> SecAccess {
    var selfApp: SecTrustedApplication?
    let appStatus = SecTrustedApplicationCreateFromPath(nil, &selfApp)
    guard appStatus == errSecSuccess, let selfApp else {
      throw AgentSettingsStoreError.keychain(status: appStatus)
    }

    var access: SecAccess?
    let accessStatus = SecAccessCreate(
      "LilPasswordsAgent agent-access settings" as CFString,
      [selfApp] as CFArray,
      &access
    )
    guard accessStatus == errSecSuccess, let access else {
      throw AgentSettingsStoreError.keychain(status: accessStatus)
    }
    return access
  }
}

/// An in-memory `AgentSettingsStoring` for tests — no real Keychain access, matching
/// `InMemoryVaultKeyStore`'s shape. `loadError`, if set, makes ``load()`` throw unconditionally, so
/// tests can exercise the "the store exists but can't be read" half of the fail-closed contract
/// without a real corrupt Keychain item.
public final class InMemoryAgentSettingsStore: AgentSettingsStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: AgentSettings?
  private let loadError: (any Error)?

  public init(initial: AgentSettings? = nil, loadError: (any Error)? = nil) {
    self.stored = initial
    self.loadError = loadError
  }

  public func load() throws -> AgentSettings? {
    lock.lock()
    defer { lock.unlock() }
    if let loadError { throw loadError }
    return stored
  }

  public func store(_ settings: AgentSettings) throws {
    lock.lock()
    defer { lock.unlock() }
    stored = settings
  }
}
