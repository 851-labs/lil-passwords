import Foundation

/// The helper's request handler: dispatches every `AgentRequest` to its `VaultStoring`, the
/// access policy, and the access log.
///
/// Lock state itself lives in `vaultStore` (`VaultStoring.isUnlocked`/`open(with:)`/`lock()`),
/// not in `AgentServer` — one `VaultStoring` instance is constructed once (by
/// `Agent/Sources/main.swift` in production, by tests otherwise) and handed to this initializer,
/// matching "the helper owns the lock state" in this ticket's description: the vault key lives in
/// the store, which lives exactly as long as the helper process does.
///
/// One `AgentServer` instance is shared across every accepted `NSXPCConnection` — lock state is
/// process-wide, not per-connection. `CallerIdentity` (per-connection) is passed into
/// ``handle(_:caller:)`` by the caller (`AgentXPCListenerDelegate`/its exported object), not
/// stored here.
public actor AgentServer {
  private let vaultStore: any VaultStoring
  private let vaultKeyStore: any VaultKeyStoring
  private let accessPolicy: any AccessPolicyProviding
  private let accessLog: any AccessLogging
  private let passwordGenerator: PasswordGenerator
  private let appCallerBundleIdentifier: String
  private let autoFillCallerBundleIdentifier: String
  private let agentSettingsStore: any AgentSettingsStoring
  private let approvalCenter: ApprovalCenter
  private let approvalTimeout: Duration

  /// - Parameters:
  ///   - vaultStore: The single `VaultStoring` this helper serves for its entire process
  ///     lifetime. Injected (rather than `AgentServer` constructing a concrete `VaultStore` itself)
  ///     so production code and tests can supply different backends (`VaultStore` vs
  ///     `InMemoryVaultStore`) without `AgentServer` depending on either concrete type.
  ///   - vaultKeyStore: Where `.createVault` persists the freshly generated vault key and
  ///     `.unlock` reads it back from — the local Keychain in production
  ///     (`KeychainVaultKeyStore`), an in-memory double in tests. Defaults to
  ///     `InMemoryVaultKeyStore()` purely so existing call sites that only care about the vault
  ///     CRUD surface (not lock lifecycle) don't all need updating; production wiring
  ///     (`Agent/Sources/main.swift`) always passes `KeychainVaultKeyStore()` explicitly.
  ///   - appCallerBundleIdentifier: The bundle identifier `isAppCaller(_:)` treats as "the app" for
  ///     `.createVault`/`.unlock` gating. Defaults to the real app's identifier
  ///     (`AgentConnectionSecurity.PeerIdentifier.app`). Overridable so an in-process XPC test
  ///     harness (`AgentXPCEndToEndTests`), whose connecting peer really is the test binary itself
  ///     — not an unsigned/ad-hoc process with no `bundleIdentifier` at all, but a normally-signed
  ///     one with *some* real, resolvable identifier (e.g. the `xctest` tool's) — can tell
  ///     `AgentServer` to trust that identifier as "the app" instead. This exercises the exact same
  ///     caller-identity-resolution and gating code production does; only which identifier counts
  ///     as trusted changes.
  ///   - autoFillCallerBundleIdentifier: The bundle identifier `isAutoFillCaller(_:)` treats as the
  ///     851-2441 AutoFill credential provider extension, for `.unlock` and the `.autoFill*`
  ///     request gating in `isRequestPermitted(_:for:)`. Defaults to the real extension's
  ///     identifier (`AgentConnectionSecurity.PeerIdentifier.autoFill`), overridable for the same
  ///     test-harness reason `appCallerBundleIdentifier` is.
  ///   - agentSettingsStore: Where `.getAgentSettings`/`.setAgentSettings` persist the 851-2428
  ///     agent-access settings, including the 851-2433 write-access toggle
  ///     (`AgentSettings.agentWriteAccessEnabled`) — the real, Keychain-backed
  ///     `KeychainAgentSettingsStore` in production, an in-memory double in tests. Defaults to
  ///     `InMemoryAgentSettingsStore()` for the same "existing call sites that don't care don't
  ///     need updating" reason `vaultKeyStore`'s default exists; production wiring
  ///     (`Agent/Sources/main.swift`) always passes `KeychainAgentSettingsStore()` explicitly, and
  ///     shares that one instance with the `AgentSettingsAccessPolicy` it also constructs.
  ///   - approvalCenter: The 851-2445 "ask every time" approval queue. Defaults to a fresh
  ///     ``ApprovalCenter`` (a `NoOpApprovalAppLauncher`, real wall-clock `Date`), which is exactly
  ///     what production wiring wants too, other than passing a real ``NSWorkspaceApprovalAppLauncher``
  ///     — see `Agent/Sources/main.swift`.
  ///   - approvalTimeout: How long a non-app caller's request waits for a decision under
  ///     `AgentAccessScope.askEveryTime` before failing with `AgentError.approvalDeniedOrTimedOut`.
  ///     Defaults to the ticket's ~60 seconds; tests override this to a much shorter `Duration` so
  ///     the timeout path doesn't actually take a minute to exercise.
  public init(
    vaultStore: any VaultStoring,
    vaultKeyStore: any VaultKeyStoring = InMemoryVaultKeyStore(),
    accessPolicy: any AccessPolicyProviding = AlwaysAllowAccessPolicy(),
    accessLog: any AccessLogging = NoOpAccessLog(),
    passwordGenerator: PasswordGenerator = PasswordGenerator(),
    appCallerBundleIdentifier: String = AgentConnectionSecurity.PeerIdentifier.app.rawValue,
    autoFillCallerBundleIdentifier: String = AgentConnectionSecurity.PeerIdentifier.autoFill.rawValue,
    agentSettingsStore: any AgentSettingsStoring = InMemoryAgentSettingsStore(),
    approvalCenter: ApprovalCenter = ApprovalCenter(),
    approvalTimeout: Duration = .seconds(60)
  ) {
    self.vaultStore = vaultStore
    self.vaultKeyStore = vaultKeyStore
    self.accessPolicy = accessPolicy
    self.accessLog = accessLog
    self.passwordGenerator = passwordGenerator
    self.appCallerBundleIdentifier = appCallerBundleIdentifier
    self.autoFillCallerBundleIdentifier = autoFillCallerBundleIdentifier
    self.agentSettingsStore = agentSettingsStore
    self.approvalCenter = approvalCenter
    self.approvalTimeout = approvalTimeout
  }

  /// Handles one already-decoded request and returns the reply envelope to send back.
  ///
  /// `caller` is threaded through to both the access policy (851-2428's app-connection exemption —
  /// see `AccessPolicyProviding.isAccessAllowed(for:)`) and the access log (see `AccessLogging`'s
  /// docs for why lock-lifecycle requests never reach the log).
  public func handle(_ envelope: AgentRequestEnvelope, caller: CallerIdentity) async -> AgentReplyEnvelope {
    guard envelope.version == AgentProtocolVersion.current else {
      return AgentReplyEnvelope(
        outcome: .failure(
          .unsupportedProtocolVersion(requested: envelope.version, supported: AgentProtocolVersion.current)
        )
      )
    }

    guard isRequestPermitted(envelope.request, for: caller) else {
      return AgentReplyEnvelope(outcome: .failure(.callerNotAuthorized))
    }

    let outcome: AgentOutcome
    switch envelope.request {
    case .status, .createVault, .unlock, .lock, .getAgentSettings, .setAgentSettings, .rotateRecoveryKey,
      .pendingApprovals, .resolveApproval:
      outcome = await lifecycleOutcome(for: envelope.request, caller: caller)
    default:
      outcome = await vaultOutcome(for: envelope.request, caller: caller)
    }
    return AgentReplyEnvelope(outcome: outcome)
  }

  /// 851-2441: the AutoFill credential provider extension's connection is trusted for exactly five
  /// operations — `.status` (always answerable, regardless of caller), `.unlock`/`.lock` (its own
  /// `LAContext`-gated "Unlock" button, the same trust rationale `.unlock`'s documentation gives the
  /// app), and the two `.autoFill*` ops built specifically for it. Every other `AgentRequest` is
  /// refused outright for this caller, `.list`/`.search`/`.getItem` included — even though those
  /// are already covered for other non-app callers by `AccessPolicyProviding`/`requireWriteAccess`,
  /// AutoFill gets no dispatch route to them at all, so "only the chosen identity, never general
  /// list/search access" (this ticket's own requirement) is structural, not just a policy that a
  /// future change to `AgentSettingsAccessPolicy` could accidentally loosen.
  ///
  /// Every other caller (the app, `lilpass`) is unaffected: this only ever narrows AutoFill's own
  /// connection, so it's checked first, before any of the existing app-only/access-policy/
  /// write-access gating below even runs.
  private func isRequestPermitted(_ request: AgentRequest, for caller: CallerIdentity) -> Bool {
    guard isAutoFillCaller(caller) else { return true }
    switch request {
    case .status, .unlock, .lock, .autoFillIdentities, .autoFillCredential:
      return true
    case .createVault, .rotateRecoveryKey, .getAgentSettings, .setAgentSettings, .list, .search, .getItem,
      .createItem, .updateItem, .deleteItem, .generatePassword, .totpCode,
      .pendingApprovals, .resolveApproval:
      // 851-2445: approval management is an app-only concern (see `isAppCaller` gating elsewhere in
      // this file) — AutoFill has no business seeing or resolving another caller's pending
      // approvals, so it's refused here alongside the rest of the general vault surface.
      return false
    }
  }

  // MARK: - Lock lifecycle and helper configuration (never logged — see AccessLogging)

  private func lifecycleOutcome(for request: AgentRequest, caller: CallerIdentity) async -> AgentOutcome {
    switch request {
    case .status:
      let locked = await !vaultStore.isUnlocked
      // A store that fails to answer `vaultExists()` (a corrupt/unreadable database, say) is
      // treated as "a vault exists" rather than "no vault yet": the former just means the app
      // shows the lock screen and a subsequent `.unlock` fails with a real error, while the
      // latter would offer to `.createVault` over — and silently orphan — whatever's actually on
      // disk.
      let exists = (try? await vaultStore.vaultExists()) ?? true
      let status = AgentStatus(
        locked: locked,
        agentAccessEnabled: await accessPolicy.isAgentAccessEnabled(),
        vaultExists: exists
      )
      return .success(.status(status))

    case .createVault:
      guard isAppCaller(caller) else { return .failure(.callerNotAuthorized) }
      do {
        let recoveryKey = try await vaultStore.createVault()
        let key = try await vaultStore.currentKey()
        try vaultKeyStore.store(key)
        LockStateNotifications.post()
        return .success(.vaultCreated(recoveryKeyDisplayString: recoveryKey.displayString))
      } catch let error as AgentError {
        return .failure(error)
      } catch let error as VaultStoreError {
        return .failure(agentError(for: error))
      } catch {
        return .failure(.internal(message: "\(error)"))
      }

    case .unlock:
      guard isAppCaller(caller) || isAutoFillCaller(caller) else { return .failure(.callerNotAuthorized) }
      do {
        guard let key = try vaultKeyStore.loadKey() else {
          // No key ever stored — either `.createVault` never ran (shouldn't happen; the app
          // always calls it on first run before offering to unlock anything) or something wiped
          // the Keychain item out from under this helper. Either way, the caller can't proceed by
          // retrying `.unlock` — surfaced as an `.internal` error rather than `.locked` (a bare
          // "wrong password" story) since there's no key material to even try.
          return .failure(.internal(message: "no vault key is stored — call .createVault first"))
        }
        try await vaultStore.open(with: key)
        LockStateNotifications.post()
        return .success(.unlocked)
      } catch let error as AgentError {
        return .failure(error)
      } catch let error as VaultStoreError {
        return .failure(agentError(for: error))
      } catch {
        return .failure(.internal(message: "\(error)"))
      }

    case .lock:
      await vaultStore.lock()
      LockStateNotifications.post()
      return .success(.locked)

    case .getAgentSettings:
      guard isAppCaller(caller) else { return .failure(.callerNotAuthorized) }
      return .success(.agentSettings(currentAgentSettings()))

    case .setAgentSettings(let settings):
      guard isAppCaller(caller) else { return .failure(.callerNotAuthorized) }
      do {
        try agentSettingsStore.store(settings)
        return .success(.agentSettings(settings))
      } catch {
        return .failure(.internal(message: "\(error)"))
      }

    case .rotateRecoveryKey:
      guard isAppCaller(caller) else { return .failure(.callerNotAuthorized) }
      do {
        let recoveryKey = try await vaultStore.rotateRecoveryKey()
        return .success(.recoveryKeyRotated(recoveryKeyDisplayString: recoveryKey.displayString))
      } catch let error as AgentError {
        return .failure(error)
      } catch let error as VaultStoreError {
        return .failure(agentError(for: error))
      } catch {
        return .failure(.internal(message: "\(error)"))
      }

    case .pendingApprovals:
      guard isAppCaller(caller) else { return .failure(.callerNotAuthorized) }
      return .success(.pendingApprovals(await approvalCenter.pendingApprovals()))

    case .resolveApproval(let id, let decision):
      guard isAppCaller(caller) else { return .failure(.callerNotAuthorized) }
      _ = await approvalCenter.resolve(id: id, decision: decision)
      return .success(.approvalResolved)

    default:
      preconditionFailure(
        "lifecycleOutcome only handles .status/.createVault/.unlock/.lock/.getAgentSettings/"
          + ".setAgentSettings/.rotateRecoveryKey/.pendingApprovals/.resolveApproval"
      )
    }
  }

  /// The 851-2428 agent-access settings, read with the same fail-closed fallback every reader of
  /// ``agentSettingsStore`` must use — see ``AgentSettings/loaded(from:)``.
  private func currentAgentSettings() -> AgentSettings {
    AgentSettings.loaded(from: agentSettingsStore)
  }

  /// Whether `caller` is allowed to send `.createVault`/`.unlock`/`.getAgentSettings`/
  /// `.setAgentSettings`/`.rotateRecoveryKey` — all five restricted to the app itself: the first
  /// two (and `.rotateRecoveryKey`, 851-2462) because only the app performs the `LAContext`
  /// authentication that's supposed to gate them (see docs/adr/0001-storage-and-process-model.md
  /// (b)), the other two because the 851-2428 Settings UI is their only intended writer/reader.
  /// `lilpass`, or any other process, must never be able to trigger any of them just by connecting
  /// to the Mach service.
  ///
  /// Delegates entirely to `CallerIdentity.isVerifiedApp(appBundleIdentifier:)` — the single,
  /// shared, code-signing-verified implementation also used by `AgentSettingsAccessPolicy`'s own
  /// app-connection exemption, so the two checks can never independently drift (see that method's
  /// documentation for why a previous, separate implementation of the policy's check was a security
  /// bug).
  private func isAppCaller(_ caller: CallerIdentity) -> Bool {
    caller.isVerifiedApp(appBundleIdentifier: appCallerBundleIdentifier)
  }

  /// The 851-2441 counterpart to ``isAppCaller(_:)``: whether `caller` is the AutoFill credential
  /// provider extension's verified connection. See ``isRequestPermitted(_:for:)`` for what this
  /// caller is actually trusted to do, which is deliberately much narrower than what
  /// `isAppCaller(_:)` grants.
  ///
  /// Deliberately **not** implemented via `CallerIdentity.isVerifiedApp(appBundleIdentifier:)`,
  /// unlike `isAppCaller(_:)`: that helper treats a caller with no resolvable `bundleIdentifier`
  /// (an unsigned/ad-hoc build with no explicit `-i` identifier, or a from-source `swift run`
  /// dev workflow) as a match in DEBUG builds — the right call for "is this the app", the single
  /// most-privileged caller, but wrong here. `isRequestPermitted(_:for:)` *restricts* whatever
  /// caller this returns `true` for down to five operations, so falling back to `true` for an
  /// unidentifiable caller would wrongly lock a real app or `lilpass` connection (which has no
  /// `-i` identifier in that same unsigned scenario) out of everything else it needs. A plain,
  /// exact `bundleIdentifier` comparison fails closed instead: an unidentifiable caller is simply
  /// never treated as AutoFill, leaving it to whatever `isAppCaller(_:)`/the existing
  /// `AccessPolicyProviding`/`requireWriteAccess` checks already decide for it.
  private func isAutoFillCaller(_ caller: CallerIdentity) -> Bool {
    caller.bundleIdentifier == autoFillCallerBundleIdentifier
  }

  /// Gates `.createItem`/`.updateItem`/`.deleteItem` for non-app callers behind the separate
  /// 851-2433 write-access toggle (`AgentSettings.agentWriteAccessEnabled`). The app itself
  /// (`isAppCaller(_:)` — the same check `.createVault`/`.unlock`/`.getAgentSettings`/
  /// `.setAgentSettings` use) is always exempt: its own "add/edit/delete password" screens go
  /// through this exact XPC path, so gating it on a toggle meant for `lilpass`/MCP would break the
  /// app's own core CRUD whenever a person turns write access off.
  ///
  /// Only reachable once ``vaultResponse(for:caller:)``'s `AccessPolicyProviding.isAccessAllowed(for:)`
  /// guard has already passed — read access must already be on before write access can matter,
  /// which is why a non-app caller with read access off sees `.agentAccessDisabled`, never
  /// `.agentWriteAccessDisabled`, even if write access happens to be stored as "on". That's also
  /// why this reads the same `agentSettingsStore`-backed ``currentAgentSettings()`` the read-access
  /// checks do, rather than a second, independent store: `agentWriteAccessEnabled` and
  /// `agentAccessEnabled` are two fields of the same struct, persisted together, so they can never
  /// independently go stale relative to each other.
  private func requireWriteAccess(for caller: CallerIdentity) throws {
    guard !isAppCaller(caller) else { return }
    guard currentAgentSettings().agentWriteAccessEnabled else { throw AgentError.agentWriteAccessDisabled }
  }

  // MARK: - Vault operations (logged via AccessLogging)

  /// A tiny mutable box for threading the 851-2445 approval outcome (if any) out of
  /// ``vaultResponse(for:caller:settings:approvalOutcomeBox:)`` for logging, even when that method
  /// throws partway through — a plain return value can't carry this alongside a thrown error, and
  /// the outcome still belongs on the access log entry for a request that was approved but then
  /// failed for some other reason (e.g. the approved item was deleted concurrently).
  private final class ApprovalOutcomeBox: @unchecked Sendable {
    var value: ApprovalOutcome?
  }

  private func vaultOutcome(for request: AgentRequest, caller: CallerIdentity) async -> AgentOutcome {
    let settings = currentAgentSettings()
    let approvalOutcomeBox = ApprovalOutcomeBox()

    let outcome: AgentOutcome
    do {
      let response = try await vaultResponse(
        for: request,
        caller: caller,
        settings: settings,
        approvalOutcomeBox: approvalOutcomeBox
      )
      outcome = .success(response)
    } catch let error as AgentError {
      outcome = .failure(error)
    } catch let error as VaultStoreError {
      outcome = .failure(agentError(for: error))
    } catch {
      outcome = .failure(.internal(message: "\(error)"))
    }

    let succeeded: Bool
    let response: AgentResponse?
    if case .success(let value) = outcome {
      succeeded = true
      response = value
    } else {
      succeeded = false
      response = nil
    }
    await accessLog.record(
      AccessEvent(
        caller: caller,
        request: request,
        response: response,
        succeeded: succeeded,
        accessMode: settings.accessScope,
        approvalOutcome: approvalOutcomeBox.value
      )
    )
    return outcome
  }

  private func vaultResponse(
    for request: AgentRequest,
    caller: CallerIdentity,
    settings: AgentSettings,
    approvalOutcomeBox: ApprovalOutcomeBox
  ) async throws -> AgentResponse {
    guard await accessPolicy.isAccessAllowed(for: caller) else { throw AgentError.agentAccessDisabled }
    guard await vaultStore.isUnlocked else { throw AgentError.locked }

    // Both scope filtering and approval gating exempt the app's own connection — see
    // `isAppCaller(_:)`'s documentation and docs/adr/0007-scoped-agent-access.md.
    let scoped = !isAppCaller(caller)

    if scoped, settings.accessScope == .askEveryTime, !request.isGeneratePassword {
      let outcome = await requestApproval(for: request, caller: caller)
      approvalOutcomeBox.value = outcome
      guard outcome != .deniedOrTimedOut else { throw AgentError.approvalDeniedOrTimedOut }
    }

    switch request {
    case .list:
      var items = try await vaultStore.allItems().filter(isLive)
      if scoped { items = filterToScope(items, settings: settings) }
      return .items(items)

    case .search(let query):
      var items = try await vaultStore.items(matching: query).filter(isLive)
      if scoped { items = filterToScope(items, settings: settings) }
      return .items(items)

    case .getItem(let reference):
      return .item(try await resolveVisible(reference, settings: settings, scoped: scoped))

    case .createItem(let item):
      try requireWriteAccess(for: caller)
      // Deliberately not auto-added to `allowedItemIDs` under `.selected` — see
      // docs/adr/0007-scoped-agent-access.md's "No existence leak" section for why a write-capable
      // agent must not be able to silently expand its own read scope.
      try await vaultStore.create(item)
      return .created(item)

    case .updateItem(let item):
      try requireWriteAccess(for: caller)
      if scoped, settings.accessScope == .selected, !isItemAllowed(item, settings: settings) {
        throw AgentError.notFound
      }
      try await vaultStore.update(item)
      return .updated(item)

    case .deleteItem(let reference):
      try requireWriteAccess(for: caller)
      // `VaultStoring.delete(id:)` only ever soft-deletes (sets `deletedAt`; see `isLive(_:)`'s
      // doc comment) — there is no permanent-delete request anywhere in `AgentRequest` for an
      // agent caller to reach, by design (851-2433).
      let item = try await resolveVisible(reference, settings: settings, scoped: scoped)
      try await vaultStore.delete(id: item.id)
      return .deleted

    case .generatePassword(let format):
      do {
        return .generatedPassword(try passwordGenerator.generate(format: format))
      } catch {
        throw AgentError.internal(message: "\(error)")
      }

    case .totpCode(let reference):
      let item = try await resolveVisible(reference, settings: settings, scoped: scoped)
      guard let totp = item.totp else {
        throw AgentError.internal(message: "item has no usable TOTP secret")
      }
      let now = Date()
      return .totpCode(TOTPCodeResult(code: totp.code(at: now), expiresAt: totp.nextChange(after: now)))

    case .autoFillIdentities(let serviceIdentifiers):
      // 851-2441: powers `prepareCredentialList(for:)`. Only items with both a matching website
      // and a non-empty username can ever be offered as an AutoFill suggestion — an item with no
      // username has nothing for `CredentialIdentity.username` to show, and `.autoFillCredential`
      // below would have nothing sensible to fill either.
      let items = try await vaultStore.allItems().filter(isLive)
      let matches = items.filter { item in
        guard !item.usernames.isEmpty else { return false }
        return serviceIdentifiers.contains { item.matchesHost(ofServiceIdentifier: $0) }
      }
      return .autoFillIdentities(
        matches.map { item in
          CredentialIdentity(id: item.id, title: item.title, username: item.usernames[0], website: item.websites.first)
        }
      )

    case .autoFillCredential(let id):
      // Deliberately its own case rather than routing through `resolve(_:)`/`.getItem`: this must
      // never be able to return anything beyond username+password for one item, by construction of
      // `AgentResponse.autoFillCredential`'s own (narrower) type — see AgentProtocol.swift.
      guard let item = try await vaultStore.item(id: id), isLive(item) else { throw AgentError.notFound }
      guard let username = item.usernames.first else { throw AgentError.notFound }
      return .autoFillCredential(username: username, password: item.password)

    case .status, .createVault, .unlock, .lock, .getAgentSettings, .setAgentSettings, .rotateRecoveryKey,
      .pendingApprovals, .resolveApproval:
      preconditionFailure("vaultResponse never sees lock-lifecycle/helper-configuration requests")
    }
  }

  /// `VaultStoring` soft-deletes: `allItems()`/`item(id:)`/`items(matching:)` keep returning a
  /// deleted record (with `deletedAt` set) until the store's next reload — see
  /// `VaultStoreSharedBehaviorTests.assertCRUDLifecycle`'s "Soft delete" comment. `AgentServer`'s
  /// wire protocol has no notion of tombstones, so every vault operation filters them out here
  /// rather than leaking that storage-layer detail to `lilpass`/the app.
  private func isLive(_ item: PasswordItem) -> Bool {
    item.deletedAt == nil
  }

  /// Whether `item` is visible to a non-app caller under `AgentAccessScope.selected` — its id is
  /// explicitly allowed, or its `group` (if it has one) is. Callers under any other scope never
  /// call this; the app itself is always exempt (see ``vaultResponse(for:caller:settings:approvalOutcomeBox:)``'s
  /// `scoped` guard at every call site).
  private func isItemAllowed(_ item: PasswordItem, settings: AgentSettings) -> Bool {
    if settings.allowedItemIDs.contains(item.id) { return true }
    if let group = item.group, settings.allowedGroups.contains(group) { return true }
    return false
  }

  private func filterToScope(_ items: [PasswordItem], settings: AgentSettings) -> [PasswordItem] {
    guard settings.accessScope == .selected else { return items }
    return items.filter { isItemAllowed($0, settings: settings) }
  }

  /// Resolves `reference` to a single item, exactly like the pre-851-2445 `resolve(_:)` did, except
  /// that under `AgentAccessScope.selected` (`scoped && settings.accessScope == .selected`) a
  /// non-allowed item is treated as if it doesn't exist at all — including, critically, *before*
  /// the `.ambiguous` check: a query matching two items where only one is allowed is resolved as a
  /// single unambiguous match (or `.notFound`, if the allowed one isn't among the matches), never
  /// `.ambiguous` — reporting "more than one item matched" would itself leak that a second,
  /// invisible item exists. See docs/adr/0007-scoped-agent-access.md's "No existence leak" section.
  private func resolveVisible(_ reference: ItemReference, settings: AgentSettings, scoped: Bool) async throws
    -> PasswordItem
  {
    switch reference {
    case .id(let id):
      guard let item = try await vaultStore.item(id: id), isLive(item) else { throw AgentError.notFound }
      if scoped, settings.accessScope == .selected, !isItemAllowed(item, settings: settings) {
        throw AgentError.notFound
      }
      return item

    case .query(let query):
      var matches = try await vaultStore.items(matching: query).filter(isLive)
      if scoped, settings.accessScope == .selected {
        matches = matches.filter { isItemAllowed($0, settings: settings) }
      }
      guard let first = matches.first else { throw AgentError.notFound }
      guard matches.count == 1 else { throw AgentError.ambiguous }
      return first
    }
  }

  /// Runs the `AgentAccessScope.askEveryTime` approval flow for one request: resolves the caller's
  /// top-level `AgentGrantIdentity`, best-effort-resolves an item title for the dialog (never lets
  /// a failure here block the prompt — an unresolvable title just means a less specific dialog, not
  /// a denied request), and asks `approvalCenter` for a decision.
  ///
  /// See docs/adr/0007-scoped-agent-access.md's "Approval flow" section for the full design.
  private func requestApproval(for request: AgentRequest, caller: CallerIdentity) async -> ApprovalOutcome {
    let identity = CallerIdentityResolver.resolveTopLevelAgentIdentity(pid: caller.pid)
    let agentDescription = (identity.executablePath as NSString).lastPathComponent
    let itemTitle = await bestEffortItemTitle(for: request)

    return await approvalCenter.requestApproval(
      for: identity,
      agentDescription: agentDescription,
      itemTitle: itemTitle,
      operationDescription: operationDescription(for: request),
      timeout: approvalTimeout
    )
  }

  /// A human description of `request` for the approval dialog, e.g. "wants to read the password
  /// for" — combined with the agent's name and (if resolved) the item's title by the app to render
  /// something like "claude (via lilpass) wants to read the password for GitHub".
  private func operationDescription(for request: AgentRequest) -> String {
    switch request {
    case .list, .search: return "wants to list your passwords"
    case .getItem: return "wants to read the password for"
    case .createItem: return "wants to create a new password"
    case .updateItem: return "wants to edit the password for"
    case .deleteItem: return "wants to delete the password for"
    case .totpCode: return "wants to read the verification code for"
    case .autoFillIdentities: return "wants to list your passwords"
    case .autoFillCredential: return "wants to read the password for"
    case .generatePassword, .status, .createVault, .unlock, .lock, .getAgentSettings, .setAgentSettings,
      .rotateRecoveryKey, .pendingApprovals, .resolveApproval:
      return "wants access to your passwords"
    }
  }

  /// Best-effort item title for the approval dialog, swallowing any resolution failure — an
  /// unresolvable reference (a bad query, a nonexistent id) just means the dialog shows no item
  /// title; the actual request still gets its own, correctly-typed error after approval runs, so
  /// this never needs to surface one itself.
  private func bestEffortItemTitle(for request: AgentRequest) async -> String? {
    let reference: ItemReference?
    switch request {
    case .getItem(let ref), .deleteItem(let ref), .totpCode(let ref):
      reference = ref
    case .updateItem(let item):
      return item.title
    default:
      reference = nil
    }
    guard let reference else { return nil }
    switch reference {
    case .id(let id):
      return try? await vaultStore.item(id: id)?.title
    case .query(let query):
      return try? await vaultStore.items(matching: query).first?.title
    }
  }

  /// Translates a `VaultStoreError` into the typed, wire-safe `AgentError` a caller should see.
  /// Only cases with an obvious, already-existing `AgentError` counterpart get one
  /// (`.itemNotFound` → `.notFound`, `.locked` → `.locked`, the latter only reachable in a race
  /// between the `isUnlocked` check above and a concurrent `.lock` request); everything else
  /// (a corrupt database, an incorrect key, a future format version) is a condition this ticket's
  /// protocol has no dedicated case for, so it falls back to `.internal` — its message is always
  /// safe to log since `VaultStoreError`'s cases never carry vault secrets.
  private func agentError(for error: VaultStoreError) -> AgentError {
    switch error {
    case .itemNotFound:
      return .notFound
    case .locked:
      return .locked
    case .vaultAlreadyExists, .vaultNotFound, .incorrectKey, .itemAlreadyExists, .unsupportedVaultFormatVersion,
      .corruptData, .sqlite:
      return .internal(message: "\(error)")
    }
  }
}
