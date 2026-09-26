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
/// in LilPasswordsKit) to exactly `.unlock`/`.autoFillIdentities`/`.autoFillCredential` — it has no
/// dispatch route at all for `.list`/`.search`/`.getItem`/any write operation, so "only the chosen
/// credential, never general list/search access" is enforced below the UI layer, not just by this
/// file choosing not to call anything else. See docs/adr/0005-autofill-credential-provider.md for
/// the full trust-model writeup, including why this extension can't yet be enabled locally
/// (provisioning profile, 851-2400).
final class CredentialProviderViewController: ASCredentialProviderViewController {
  private let agentClient = AgentClient()
  private let authenticator: DeviceAuthenticating = LAContextDeviceAuthenticator()

  // MARK: List UI — `prepareCredentialList(for:)`

  private let listContainer = NSView()
  private let searchField = NSSearchField()
  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private let statusField = NSTextField(wrappingLabelWithString: "")

  private var serviceIdentifiers: [ASCredentialServiceIdentifier] = []
  private var identities: [CredentialIdentity] = []
  private var filteredIdentities: [CredentialIdentity] = [] {
    didSet { tableView.reloadData() }
  }

  // MARK: Locked UI — shared by the list flow and `prepareInterfaceToProvideCredential(for:)`

  private let lockedContainer = NSView()
  private let lockedTitleField = NSTextField(labelWithString: "lil passwords is locked")
  private let lockedSubtitleField = NSTextField(wrappingLabelWithString: "Unlock lil passwords to use AutoFill.")
  private let unlockButton = NSButton(title: "Unlock…", target: nil, action: nil)
  private let unlockErrorField = NSTextField(wrappingLabelWithString: "")

  /// Set only by `prepareInterfaceToProvideCredential(for:)`, when the system is asking for one
  /// specific already-known identity while the vault happens to be locked — the Unlock button
  /// retries exactly this identity afterward instead of falling back to the searchable list, which
  /// this entry point never shows.
  private var pendingCredentialIdentity: ASPasswordCredentialIdentity?

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
    showLocked()
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
      showList(loading: false, statusMessage: "Couldn't reach lil passwords' background helper.")
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
        try await authenticator.authenticate(reason: "Unlock lil passwords to use AutoFill")
        try await agentClient.unlock()
        await retryAfterUnlock()
      } catch {
        unlockButton.isEnabled = true
        unlockErrorField.stringValue = "Couldn't unlock lil passwords."
        unlockErrorField.isHidden = false
      }
    }
  }

  /// After a successful unlock: retries the one identity the system originally asked for (if this
  /// locked screen was reached via `prepareInterfaceToProvideCredential(for:)`), or falls back to
  /// loading the full searchable list (if it was reached from `prepareCredentialList(for:)`
  /// discovering the vault was locked).
  private func retryAfterUnlock() async {
    unlockButton.isEnabled = true
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
    let row = tableView.clickedRow
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
      statusField.stringValue = "Loading…"
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
    searchField.placeholderString = "Search"
    searchField.delegate = self

    tableView.headerView = nil
    tableView.rowHeight = 56
    tableView.backgroundColor = .clear
    tableView.selectionHighlightStyle = .regular
    tableView.dataSource = self
    tableView.delegate = self
    tableView.target = self
    tableView.action = #selector(rowClicked)
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
