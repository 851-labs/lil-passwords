import AppKit
import AuthenticationServices
import LilPasswordsKit

/// The whole `AutoFillExtension` app extension bundle's one view controller (851-2441). Whatever
/// screen the system shows the user — the searchable credential list, or this file's own
/// locked-state UI — is presented through this single class, since `ASCredentialProviderViewController`
/// itself is the extension's entry point.
///
/// This never touches the vault directly. Every credential lookup and every unlock goes over XPC
/// to `LilPasswordsAgent` via `AgentClient` — the same client the app and `lilpass` use — which is
/// the only process (per docs/adr/0001-storage-and-process-model.md) allowed to open the vault.
/// The helper structurally restricts this specific caller (see `AgentServer.isRequestPermitted(_:for:)`
/// in LilPasswordsKit) to exactly `.status`/`.unlock`/`.lock`/`.autoFillIdentities`/
/// `.autoFillCredential`/`.passkeyRegister`/`.passkeyAssert` — it has no dispatch route at all for
/// `.list`/`.search`/`.getItem`/`.passkeys`/any write operation on a `PasswordItem`, so "only the
/// chosen credential, never general list/search access" is enforced below the UI layer, not just by
/// this file choosing not to call anything else. See docs/adr/0005-autofill-credential-provider.md
/// for the full trust-model writeup, including why this extension can't yet be enabled locally
/// (provisioning profile, 851-2400).
///
/// **Passkeys (851-2442, macOS 14+):** the four `@available(macOS 14, *)` overrides below
/// implement registration and assertion the same no-secret-on-this-side way — a private key is
/// generated (`prepareInterface(forPasskeyRegistration:)`) or used
/// (`provideCredentialWithoutUserInteraction(for:)`/`prepareInterfaceToProvideCredential(for:)`)
/// entirely inside `LilPasswordsAgent`; this file only ever sees the resulting public
/// `credentialId`/`attestationObject`/`signature`/`authenticatorData` bytes, via
/// `AgentClient.passkeyRegister(_:)`/`passkeyAssert(_:)`. `prepareCredentialList(for:requestParameters:)`
/// deliberately still only lists passwords — see that override's own doc comment for why the
/// interactive passkey picker is a scoped-out follow-up, not an oversight.
final class CredentialProviderViewController: ASCredentialProviderViewController {
  private let agentClient = AgentClient()
  private let authenticator: DeviceAuthenticating = LAContextDeviceAuthenticator()

  // MARK: List UI — `prepareCredentialList(for:)`

  private let listContainer = NSView()
  private let searchField = NSSearchField()
  private let scrollView = NSScrollView()
  private let tableView = CredentialTableView()
  private let statusField = NSTextField(wrappingLabelWithString: "")

  private var serviceIdentifiers: [ASCredentialServiceIdentifier] = []
  private var identities: [CredentialIdentity] = []
  private var filteredIdentities: [CredentialIdentity] = [] {
    didSet { tableView.reloadData() }
  }

  // MARK: Locked UI — shared by the list flow and `prepareInterfaceToProvideCredential(for:)`

  private let lockedContainer = NSView()
  private let lockedTitleField = NSTextField(
    labelWithString: String(localized: "\(LilPasswordsKit.productName) is locked"))
  private let lockedSubtitleField = NSTextField(
    wrappingLabelWithString: String(localized: "Unlock \(LilPasswordsKit.productName) to use AutoFill."))
  private let unlockButton = NSButton(title: String(localized: "Unlock…"), target: nil, action: nil)
  private let unlockErrorField = NSTextField(wrappingLabelWithString: "")

  /// Set only by `prepareInterfaceToProvideCredential(for:)`, when the system is asking for one
  /// specific already-known identity while the vault happens to be locked — the Unlock button
  /// retries exactly this identity afterward instead of falling back to the searchable list, which
  /// this entry point never shows.
  private var pendingCredentialIdentity: ASPasswordCredentialIdentity?

  /// The passkey analog of ``pendingCredentialIdentity``, set by the macOS 14+ overrides below
  /// when the vault is locked at the moment a passkey registration or assertion was requested.
  /// Deliberately plain `Data`/`String`, not `ASPasskeyCredentialRequest`/`ASPasskeyCredentialIdentity`
  /// themselves, so this property (and the enum below) need no `@available(macOS 14, *)` of their
  /// own and can sit alongside ``pendingCredentialIdentity`` as ordinary stored state.
  private enum PendingPasskeyAction {
    case assert(credentialId: Data, relyingPartyIdentifier: String, clientDataHash: Data)
    case register(
      relyingPartyIdentifier: String, userHandle: Data, userName: String, userDisplayName: String,
      clientDataHash: Data)
  }
  private var pendingPasskeyAction: PendingPasskeyAction?

  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 420))
    configureListContainer()
    configureLockedContainer()
    showList(loading: false)
  }

  // MARK: - ASCredentialProviderViewController

  override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
    self.serviceIdentifiers = serviceIdentifiers
    pendingCredentialIdentity = nil
    pendingPasskeyAction = nil
    showList(loading: true)
    Task { await loadIdentities() }
  }

  override func provideCredentialWithoutUserInteraction(for credentialIdentity: ASPasswordCredentialIdentity) {
    guard let id = UUID(uuidString: credentialIdentity.recordIdentifier ?? "") else {
      extensionContext.cancelRequest(withError: ASExtensionError(.credentialIdentityNotFound))
      return
    }
    Task {
      do {
        let credential = try await agentClient.autoFillCredential(id: id)
        completeRequest(username: credential.username, password: credential.password)
      } catch AgentClient.RequestError.remote(.locked) {
        // No UI is on screen for this entry point. Throwing `.userInteractionRequired` here is
        // exactly what makes the system re-invoke us through
        // `prepareInterfaceToProvideCredential(for:)` instead, where showing UI (the Unlock
        // button below) is possible.
        extensionContext.cancelRequest(withError: ASExtensionError(.userInteractionRequired))
      } catch {
        extensionContext.cancelRequest(withError: ASExtensionError(.failed))
      }
    }
  }

  override func prepareInterfaceToProvideCredential(for credentialIdentity: ASPasswordCredentialIdentity) {
    pendingCredentialIdentity = credentialIdentity
    pendingPasskeyAction = nil
    showLocked()
  }

  // MARK: - Passkeys (851-2442, macOS 14+)

  /// The interactive picker still only lists passwords (``loadIdentities()`` below, unchanged from
  /// the pre-passkey `prepareCredentialList(for:)` override above) —
  /// `provideCredentialWithoutUserInteraction(for:)` is what fully implements this ticket's passkey
  /// assertion path, and that's the path the system actually takes for an existing, already-synced
  /// passkey (see `ASCredentialIdentityStoreSync`). Listing existing passkeys here too, so a person
  /// could also pick one from this searchable list by hand, would need reading the credential id
  /// back out of `ASCredentialIdentityStore` itself — `AgentClient.passkeys()`'s
  /// `PasskeyMetadata` deliberately never carries one, see AgentProtocol.swift — and is left as a
  /// follow-up rather than guessed at here.
  @available(macOS 14, *)
  override func prepareCredentialList(
    for serviceIdentifiers: [ASCredentialServiceIdentifier],
    requestParameters: ASPasskeyCredentialRequestParameters
  ) {
    prepareCredentialList(for: serviceIdentifiers)
  }

  @available(macOS 14, *)
  override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
    if let passwordIdentity = credentialRequest.credentialIdentity as? ASPasswordCredentialIdentity {
      provideCredentialWithoutUserInteraction(for: passwordIdentity)
      return
    }
    guard
      let passkeyRequest = credentialRequest as? ASPasskeyCredentialRequest,
      let passkeyIdentity = passkeyRequest.credentialIdentity as? ASPasskeyCredentialIdentity
    else {
      extensionContext.cancelRequest(withError: ASExtensionError(.credentialIdentityNotFound))
      return
    }
    Task {
      do {
        try await completePasskeyAssertion(
          credentialId: passkeyIdentity.credentialID,
          relyingPartyIdentifier: passkeyIdentity.relyingPartyIdentifier,
          clientDataHash: passkeyRequest.clientDataHash
        )
      } catch AgentClient.RequestError.remote(.locked) {
        // Same reasoning as the password path above: no UI is on screen here, so throw
        // `.userInteractionRequired` to make the system re-invoke us through
        // `prepareInterfaceToProvideCredential(for:)`, where the Unlock button can show.
        extensionContext.cancelRequest(withError: ASExtensionError(.userInteractionRequired))
      } catch {
        extensionContext.cancelRequest(withError: ASExtensionError(.failed))
      }
    }
  }

  @available(macOS 14, *)
  override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
    if let passwordIdentity = credentialRequest.credentialIdentity as? ASPasswordCredentialIdentity {
      prepareInterfaceToProvideCredential(for: passwordIdentity)
      return
    }
    guard
      let passkeyRequest = credentialRequest as? ASPasskeyCredentialRequest,
      let passkeyIdentity = passkeyRequest.credentialIdentity as? ASPasskeyCredentialIdentity
    else {
      extensionContext.cancelRequest(withError: ASExtensionError(.failed))
      return
    }
    pendingCredentialIdentity = nil
    pendingPasskeyAction = .assert(
      credentialId: passkeyIdentity.credentialID,
      relyingPartyIdentifier: passkeyIdentity.relyingPartyIdentifier,
      clientDataHash: passkeyRequest.clientDataHash
    )
    showLocked()
  }

  /// Registration's one entry point — there's no password equivalent, and unlike the assertion
  /// path there's no separate "without user interaction" variant to try first: the system always
  /// shows this extension's interface to create a brand-new passkey.
  @available(macOS 14, *)
  override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
    guard
      let passkeyRequest = registrationRequest as? ASPasskeyCredentialRequest,
      let identity = passkeyRequest.credentialIdentity as? ASPasskeyCredentialIdentity
    else {
      extensionContext.cancelRequest(withError: ASExtensionError(.failed))
      return
    }
    pendingCredentialIdentity = nil
    // `ASPasskeyCredentialIdentity` has no `userDisplayName` of its own — only `userName` — so
    // this passes through empty, matching `PasskeyRegistrationRequest.userDisplayName`/
    // `PasskeyItem.displayName`'s own "falls back to userName when empty" convention rather than
    // duplicating `userName` into both fields.
    Task {
      do {
        try await completePasskeyRegistration(
          relyingPartyIdentifier: identity.relyingPartyIdentifier,
          userHandle: identity.userHandle,
          userName: identity.userName,
          userDisplayName: "",
          clientDataHash: passkeyRequest.clientDataHash
        )
      } catch AgentClient.RequestError.remote(.locked) {
        pendingPasskeyAction = .register(
          relyingPartyIdentifier: identity.relyingPartyIdentifier,
          userHandle: identity.userHandle,
          userName: identity.userName,
          userDisplayName: "",
          clientDataHash: passkeyRequest.clientDataHash
        )
        showLocked()
      } catch {
        extensionContext.cancelRequest(withError: ASExtensionError(.failed))
      }
    }
  }

  /// Signs a passkey assertion over XPC and completes the request — the one place both
  /// ``provideCredentialWithoutUserInteraction(for:)`` and the post-unlock retry in
  /// ``retryAfterUnlock()`` funnel through, so the `ASPasskeyAssertionCredential` construction and
  /// completion call only exist once. Throws rather than handling its own errors, since the two
  /// call sites need different behavior specifically for `.locked` (see each's own catch clause).
  @available(macOS 14, *)
  private func completePasskeyAssertion(
    credentialId: Data, relyingPartyIdentifier: String, clientDataHash: Data
  ) async throws {
    let result = try await agentClient.passkeyAssert(
      PasskeyAssertionRequest(
        credentialId: credentialId, relyingPartyIdentifier: relyingPartyIdentifier, clientDataHash: clientDataHash)
    )
    let credential = ASPasskeyAssertionCredential(
      userHandle: result.userHandle,
      relyingParty: relyingPartyIdentifier,
      signature: result.signature,
      clientDataHash: clientDataHash,
      authenticatorData: result.authenticatorData,
      credentialID: credentialId
    )
    extensionContext.completeAssertionRequest(using: credential, completionHandler: nil)
  }

  /// The registration analog of ``completePasskeyAssertion(credentialId:relyingPartyIdentifier:clientDataHash:)``
  /// — the private key itself is generated inside `LilPasswordsAgent` by `agentClient.passkeyRegister(_:)`
  /// and never appears here, only the resulting `credentialId`/`attestationObject`.
  @available(macOS 14, *)
  private func completePasskeyRegistration(
    relyingPartyIdentifier: String, userHandle: Data, userName: String, userDisplayName: String, clientDataHash: Data
  ) async throws {
    let result = try await agentClient.passkeyRegister(
      PasskeyRegistrationRequest(
        relyingPartyIdentifier: relyingPartyIdentifier, userHandle: userHandle, userName: userName,
        userDisplayName: userDisplayName)
    )
    let credential = ASPasskeyRegistrationCredential(
      relyingParty: relyingPartyIdentifier,
      clientDataHash: clientDataHash,
      credentialID: result.credentialId,
      attestationObject: result.attestationObject
    )
    extensionContext.completeRegistrationRequest(using: credential, completionHandler: nil)
  }

  // MARK: - Loading the list

  private func loadIdentities() async {
    do {
      let identifiers = serviceIdentifiers.map(\.identifier)
      let fetched = try await agentClient.autoFillIdentities(serviceIdentifiers: identifiers)
      identities = fetched
      filteredIdentities = fetched
      showList(loading: false)
    } catch AgentClient.RequestError.remote(.locked) {
      showLocked()
    } catch {
      showList(
        loading: false,
        statusMessage: String(localized: "Couldn't reach \(LilPasswordsKit.productName)' background helper."))
    }
  }

  private func filterIdentities() {
    let query = searchField.stringValue
    guard !query.isEmpty else {
      filteredIdentities = identities
      return
    }
    filteredIdentities = identities.filter {
      $0.title.localizedCaseInsensitiveContains(query) || $0.username.localizedCaseInsensitiveContains(query)
    }
  }

  // MARK: - Unlocking

  @objc private func unlockButtonClicked() {
    unlockErrorField.isHidden = true
    unlockButton.isEnabled = false
    Task {
      do {
        try await authenticator.authenticate(
          reason: String(localized: "Unlock \(LilPasswordsKit.productName) to use AutoFill"))
        try await agentClient.unlock()
        await retryAfterUnlock()
      } catch {
        unlockButton.isEnabled = true
        unlockErrorField.stringValue = String(localized: "Couldn't unlock \(LilPasswordsKit.productName).")
        unlockErrorField.isHidden = false
      }
    }
  }

  /// After a successful unlock: retries the one identity the system originally asked for (if this
  /// locked screen was reached via `prepareInterfaceToProvideCredential(for:)` or, on macOS 14+,
  /// its passkey counterparts below), or falls back to loading the full searchable list (if it was
  /// reached from `prepareCredentialList(for:)` discovering the vault was locked).
  private func retryAfterUnlock() async {
    unlockButton.isEnabled = true
    if #available(macOS 14, *), let pendingPasskeyAction {
      self.pendingPasskeyAction = nil
      do {
        switch pendingPasskeyAction {
        case .assert(let credentialId, let relyingPartyIdentifier, let clientDataHash):
          try await completePasskeyAssertion(
            credentialId: credentialId, relyingPartyIdentifier: relyingPartyIdentifier, clientDataHash: clientDataHash)
        case .register(let relyingPartyIdentifier, let userHandle, let userName, let userDisplayName, let clientDataHash):
          try await completePasskeyRegistration(
            relyingPartyIdentifier: relyingPartyIdentifier, userHandle: userHandle, userName: userName,
            userDisplayName: userDisplayName, clientDataHash: clientDataHash)
        }
      } catch {
        extensionContext.cancelRequest(withError: ASExtensionError(.failed))
      }
      return
    }
    let recordIdentifier = pendingCredentialIdentity?.recordIdentifier ?? ""
    guard let pendingCredentialIdentity, let id = UUID(uuidString: recordIdentifier) else {
      showList(loading: true)
      await loadIdentities()
      return
    }
    do {
      let credential = try await agentClient.autoFillCredential(id: id)
      completeRequest(username: credential.username, password: credential.password)
    } catch {
      extensionContext.cancelRequest(withError: ASExtensionError(.failed))
    }
  }

  // MARK: - Completing the request

  private func completeRequest(username: String, password: String) {
    let credential = ASPasswordCredential(user: username, password: password)
    extensionContext.completeRequest(withSelectedCredential: credential, completionHandler: nil)
  }

  @objc private func rowClicked() {
    activateRow(tableView.clickedRow)
  }

  /// `insertNewline(_:)` on ``CredentialTableView`` below (Return/Enter) reaches here too, via
  /// `tableView.selectedRow` — mirrors `ItemTableView`'s "Return activates the selected row"
  /// keyboard-navigation behavior in the main app's item list (docs/accessibility.md), which a
  /// plain `NSTableView` doesn't provide on its own: only mouse clicks invoke `action` by default.
  private func activateRow(_ row: Int) {
    guard row >= 0, row < filteredIdentities.count else { return }
    let identity = filteredIdentities[row]
    Task {
      do {
        let credential = try await agentClient.autoFillCredential(id: identity.id)
        completeRequest(username: credential.username, password: credential.password)
      } catch AgentClient.RequestError.remote(.locked) {
        pendingCredentialIdentity = nil
        showLocked()
      } catch {
        extensionContext.cancelRequest(withError: ASExtensionError(.failed))
      }
    }
  }

  // MARK: - View state

  private func showList(loading: Bool, statusMessage: String? = nil) {
    lockedContainer.isHidden = true
    listContainer.isHidden = false
    if loading {
      statusField.stringValue = String(localized: "Loading…")
      statusField.isHidden = false
      scrollView.isHidden = true
    } else if let statusMessage {
      statusField.stringValue = statusMessage
      statusField.isHidden = false
      scrollView.isHidden = true
    } else {
      statusField.isHidden = true
      scrollView.isHidden = false
    }
  }

  private func showLocked() {
    listContainer.isHidden = true
    lockedContainer.isHidden = false
    unlockErrorField.isHidden = true
    unlockButton.isEnabled = true
  }

  // MARK: - Layout

  private func configureListContainer() {
    listContainer.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(listContainer)
    NSLayoutConstraint.activate([
      listContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      listContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      listContainer.topAnchor.constraint(equalTo: view.topAnchor),
      listContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    searchField.translatesAutoresizingMaskIntoConstraints = false
    searchField.placeholderString = String(localized: "Search")
    // The placeholder alone isn't reliably surfaced by VoiceOver as the field's accessible name
    // (docs/accessibility.md's "icon-only controls" rule generalizes to any control whose visible
    // label is decorative/placeholder text, not a real label) — an explicit label makes VoiceOver
    // announce something more useful than "search text field" alone.
    searchField.setAccessibilityLabel(String(localized: "Search credentials"))
    searchField.delegate = self

    tableView.headerView = nil
    tableView.rowHeight = 56
    tableView.backgroundColor = .clear
    tableView.selectionHighlightStyle = .regular
    tableView.dataSource = self
    tableView.delegate = self
    tableView.target = self
    tableView.action = #selector(rowClicked)
    tableView.onReturnKey = { [weak self] in
      guard let self else { return }
      self.activateRow(self.tableView.selectedRow)
    }
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("credential"))
    column.width = 356
    tableView.addTableColumn(column)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false

    statusField.translatesAutoresizingMaskIntoConstraints = false
    statusField.alignment = .center
    statusField.textColor = .secondaryLabelColor
    statusField.isHidden = true

    listContainer.addSubview(searchField)
    listContainer.addSubview(scrollView)
    listContainer.addSubview(statusField)

    NSLayoutConstraint.activate([
      searchField.topAnchor.constraint(equalTo: listContainer.topAnchor, constant: 12),
      searchField.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor, constant: 12),
      searchField.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor, constant: -12),

      scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
      scrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),

      statusField.centerXAnchor.constraint(equalTo: listContainer.centerXAnchor),
      statusField.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
      statusField.leadingAnchor.constraint(greaterThanOrEqualTo: listContainer.leadingAnchor, constant: 24),
      statusField.trailingAnchor.constraint(lessThanOrEqualTo: listContainer.trailingAnchor, constant: -24),
    ])
  }

  private func configureLockedContainer() {
    lockedContainer.translatesAutoresizingMaskIntoConstraints = false
    lockedContainer.isHidden = true
    view.addSubview(lockedContainer)
    NSLayoutConstraint.activate([
      lockedContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      lockedContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      lockedContainer.topAnchor.constraint(equalTo: view.topAnchor),
      lockedContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    lockedTitleField.font = .boldSystemFont(ofSize: 15)
    lockedTitleField.alignment = .center

    lockedSubtitleField.font = .systemFont(ofSize: 12)
    lockedSubtitleField.textColor = .secondaryLabelColor
    lockedSubtitleField.alignment = .center

    unlockButton.target = self
    unlockButton.action = #selector(unlockButtonClicked)
    unlockButton.bezelStyle = .rounded
    unlockButton.keyEquivalent = "\r"

    unlockErrorField.font = .systemFont(ofSize: 11)
    unlockErrorField.textColor = .systemRed
    unlockErrorField.alignment = .center
    unlockErrorField.isHidden = true

    let stack = NSStackView(views: [lockedTitleField, lockedSubtitleField, unlockButton, unlockErrorField])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    lockedContainer.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: lockedContainer.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: lockedContainer.centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: lockedContainer.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: lockedContainer.trailingAnchor, constant: -24),
    ])
  }
}

// MARK: - NSTableViewDataSource / NSTableViewDelegate

extension CredentialProviderViewController: NSTableViewDataSource, NSTableViewDelegate {
  func numberOfRows(in tableView: NSTableView) -> Int {
    filteredIdentities.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let identity = filteredIdentities[row]
    let rowView = CredentialRowView.dequeue(from: tableView, owner: self)
    let isLastRow = row == filteredIdentities.count - 1
    rowView.configure(title: identity.title, subtitle: identity.username, hidesSeparator: isLastRow)
    return rowView
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    56
  }
}

// MARK: - NSSearchField

extension CredentialProviderViewController: NSSearchFieldDelegate {
  func controlTextDidChange(_ obj: Notification) {
    filterIdentities()
  }
}

/// A plain `NSTableView` that turns Return/Enter into a callback — mirrors `ItemTableView` in
/// `App/Sources/MainWindow/ItemListViewController.swift` (851-2426's "Return activates the
/// selected row" keyboard-navigation rule, docs/accessibility.md), which a stock `NSTableView`
/// doesn't do on its own: only `target`/`action` on a mouse click fires without this override.
private final class CredentialTableView: NSTableView {
  var onReturnKey: (() -> Void)?

  /// `insertNewline(_:)` is `NSResponder`'s standard action for Return/Enter
  /// (`NSStandardKeyBindingResponding`), same mechanism `ItemTableView.insertNewline(_:)` uses.
  override func insertNewline(_ sender: Any?) {
    onReturnKey?()
  }
}
