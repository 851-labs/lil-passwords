import AppKit
import Combine
import LilPasswordsKit

/// The detail column: shows the selected item — a large icon/title header plus grouped
/// User Name, Password, Verification Code, Websites, and Notes sections — or the "nothing
/// selected" empty state, matching Apple Passwords.
///
/// Reads and writes go through `VaultViewModel` (the in-memory stand-in for `VaultStore`,
/// 851-2404), so once the real vault lands this controller doesn't change, only what's injected
/// at `MainSplitViewController` does.
@MainActor
final class DetailViewController: NSViewController {
  private let vaultViewModel: VaultViewModel
  private var cancellable: AnyCancellable?

  /// The id of the item being shown, or `nil` when nothing is selected. Looked up fresh from
  /// `vaultViewModel.items` rather than cached, so external changes (e.g. a save made from
  /// elsewhere) are picked up automatically.
  private var itemID: UUID?
  private var item: PasswordItem? {
    guard let itemID else { return nil }
    return vaultViewModel.items.first { $0.id == itemID }
  }

  /// The working copy being mutated while `isEditing` is true. `websiteDrafts` shadows
  /// `draft?.websites` as raw strings for the duration of the edit, since a partially-typed URL
  /// (e.g. "github.co") isn't valid `URL` yet but still needs to be editable text.
  private var draft: PasswordItem?
  private var websiteDrafts: [String] = []
  private var isEditing = false

  private var usernameListEditor: EditableListEditor?
  private var websiteListEditor: EditableListEditor?

  private let emptyStateView = EmptyStateView()
  private let contentContainer = NSView()
  private let scrollView = NSScrollView()
  private let documentStack = NSStackView()

  private let headerView = DetailHeaderView()

  private let usernameSection = DetailSectionContainerView()
  private let passwordSection = DetailSectionContainerView()
  private let verificationSection = DetailSectionContainerView()
  private let websitesSection = DetailSectionContainerView()
  private let notesSection = DetailSectionContainerView()

  init(vaultViewModel: VaultViewModel) {
    self.vaultViewModel = vaultViewModel
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func loadView() {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false

    configureEmptyState(in: view)
    configureContentContainer(in: view)

    self.view = view
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    // A caller (currently `MainSplitViewController`, auto-selecting the first item at launch)
    // may have already called `show(item:)` before the view loaded. Don't clobber that state.
    if let itemID, let item = vaultViewModel.items.first(where: { $0.id == itemID }) {
      show(item: item)
    } else {
      showNoSelection(for: .all)
    }

    cancellable = vaultViewModel.itemsDidChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.handleItemsChanged() }
  }

  // MARK: Selection

  /// Called by `MainSplitViewController` when the sidebar selection changes, so the empty
  /// state's wording can match ("No Password Selected" vs. "No Passkey Selected", etc).
  func showNoSelection(for category: SidebarCategory) {
    itemID = nil
    draft = nil
    websiteDrafts = []
    isEditing = false

    emptyStateView.configure(
      symbolName: category.symbolName,
      title: "No \(singularNoun(for: category)) Selected",
      message: nil
    )
    emptyStateView.isHidden = false
    contentContainer.isHidden = true
  }

  /// Shows `item`'s detail. Callers (currently just `MainSplitViewController`, until the item
  /// list wires up real selection) should call this whenever the selected item changes.
  func show(item: PasswordItem) {
    itemID = item.id
    draft = nil
    websiteDrafts = []
    isEditing = false

    emptyStateView.isHidden = true
    contentContainer.isHidden = false
    reloadContent()
  }

  private func handleItemsChanged() {
    guard itemID != nil else { return }
    if item == nil {
      // The selected item was deleted (here or elsewhere) out from under us.
      showNoSelection(for: .all)
    } else if !isEditing {
      reloadContent()
    }
  }

  private func singularNoun(for category: SidebarCategory) -> String {
    switch category {
    case .all: "Password"
    case .passkeys: "Passkey"
    case .codes: "Code"
    case .wifi: "Network"
    case .security: "Item"
    case .deleted: "Item"
    }
  }

  // MARK: Layout

  private func configureEmptyState(in view: NSView) {
    emptyStateView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(emptyStateView)
    NSLayoutConstraint.activate([
      emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      emptyStateView.topAnchor.constraint(equalTo: view.topAnchor),
      emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func configureContentContainer(in view: NSView) {
    contentContainer.translatesAutoresizingMaskIntoConstraints = false
    contentContainer.isHidden = true
    view.addSubview(contentContainer)
    NSLayoutConstraint.activate([
      contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      // `safeAreaLayoutGuide`, not `view.topAnchor`: this detail pane is added to the split view
      // via the plain `NSSplitViewItem(viewController:)` initializer, which — unlike the
      // sidebar/list columns' convenience initializers — doesn't pre-inset its content below the
      // unified toolbar. Pinning to the raw top anchor let the scrollable document (see
      // `scrollView` below) scroll its content up underneath the toolbar's translucent
      // background, ghosting through it. The safe area guide reflects the real toolbar height
      // regardless of how the split item was constructed, so this keeps the whole scrollable
      // region — not just its resting position — clipped below the toolbar.
      contentContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    documentStack.orientation = .vertical
    documentStack.alignment = .leading
    documentStack.spacing = 20
    documentStack.edgeInsets = NSEdgeInsets(top: 8, left: 24, bottom: 24, right: 24)
    documentStack.translatesAutoresizingMaskIntoConstraints = false

    headerView.onTitleChange = { [weak self] newTitle in
      self?.draft?.title = newTitle
    }
    headerView.onEditTapped = { [weak self] in self?.editTapped() }
    headerView.onCancelTapped = { [weak self] in self?.cancelTapped() }
    headerView.onDoneTapped = { [weak self] in self?.doneTapped() }

    for section in [usernameSection, passwordSection, verificationSection, websitesSection, notesSection] {
      documentStack.addArrangedSubview(section)
      section.widthAnchor.constraint(equalTo: documentStack.widthAnchor, constant: -48).isActive = true
    }
    documentStack.addArrangedSubview(headerView)
    documentStack.setCustomSpacing(24, after: headerView)
    // The header reads best first; `addArrangedSubview` above just registered widths, so move it
    // to the front now that every view exists.
    documentStack.removeArrangedSubview(headerView)
    documentStack.insertArrangedSubview(headerView, at: 0)
    headerView.widthAnchor.constraint(equalTo: documentStack.widthAnchor, constant: -48).isActive = true

    let flippedDocumentView = FlippedView()
    flippedDocumentView.translatesAutoresizingMaskIntoConstraints = false
    flippedDocumentView.addSubview(documentStack)
    NSLayoutConstraint.activate([
      documentStack.leadingAnchor.constraint(equalTo: flippedDocumentView.leadingAnchor),
      documentStack.trailingAnchor.constraint(equalTo: flippedDocumentView.trailingAnchor),
      documentStack.topAnchor.constraint(equalTo: flippedDocumentView.topAnchor),
      documentStack.bottomAnchor.constraint(equalTo: flippedDocumentView.bottomAnchor),
    ])
    scrollView.documentView = flippedDocumentView
    NSLayoutConstraint.activate([
      flippedDocumentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
    ])

    contentContainer.addSubview(scrollView)
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
    ])
  }

  // MARK: Edit mode

  @objc
  private func editTapped() {
    guard let item else { return }
    draft = item
    websiteDrafts = item.websites.map(\.absoluteString)
    isEditing = true
    reloadContent()
  }

  @objc
  private func cancelTapped() {
    draft = nil
    websiteDrafts = []
    isEditing = false
    reloadContent()
  }

  @objc
  private func doneTapped() {
    guard var finalItem = draft else { return }

    finalItem.title = {
      let trimmed = finalItem.title.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? "Untitled" : trimmed
    }()
    finalItem.usernames = finalItem.usernames
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    finalItem.websites =
      websiteDrafts
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .compactMap(Self.normalizedWebsiteURL)

    vaultViewModel.save(finalItem)

    draft = nil
    websiteDrafts = []
    isEditing = false
    reloadContent()
  }

  private static func normalizedWebsiteURL(from string: String) -> URL? {
    if let url = URL(string: string), url.scheme != nil {
      return url
    }
    return URL(string: "https://\(string)")
  }

  // MARK: Content

  private func reloadContent() {
    guard let displayItem = isEditing ? draft : item else { return }

    headerView.configure(
      title: displayItem.title,
      icon: MonogramIcon.icon(for: displayItem.title, dimension: 64),
      modifiedAt: displayItem.modifiedAt,
      isEditing: isEditing
    )

    configureUsernameSection(displayItem)
    configurePasswordSection(displayItem)
    configureVerificationSection(displayItem)
    configureWebsitesSection(displayItem)
    configureNotesSection(displayItem)
  }

  private func configureUsernameSection(_ displayItem: PasswordItem) {
    if isEditing {
      usernameSection.isHidden = false
      usernameListEditor = EditableListEditor(
        section: usernameSection,
        values: displayItem.usernames,
        placeholder: "Username or Email",
        addButtonTitle: "Add Username"
      ) { [weak self] newValues in
        self?.draft?.usernames = newValues
      }
    } else {
      usernameListEditor = nil
      usernameSection.isHidden = displayItem.usernames.isEmpty
      // Apple Passwords labels only the first row when there's more than one username (using
      // the plural "User Names"), leaving the rest unlabeled rather than repeating the label.
      let label = displayItem.usernames.count > 1 ? "User Names" : "User Name"
      let rows: [NSView] = displayItem.usernames.enumerated().map { index, username in
        let row = DetailValueRowView()
        row.configure(label: index == 0 ? label : "", value: username)
        row.onCopy = { Pasteboard.copySecret(username) }
        return row
      }
      usernameSection.setRows(rows)
    }
  }

  private func configurePasswordSection(_ displayItem: PasswordItem) {
    if isEditing {
      let row = PasswordEditRowView(value: displayItem.password)
      row.onValueChange = { [weak self] newValue in
        self?.draft?.password = newValue
      }
      passwordSection.setRows([row])
    } else {
      let row = PasswordRowView()
      row.configure(password: displayItem.password)
      row.onCopy = { Pasteboard.copySecret(displayItem.password) }
      passwordSection.setRows([row])
    }
  }

  private func configureVerificationSection(_ displayItem: PasswordItem) {
    if isEditing {
      var rows: [NSView] = [
        makeInfoRow(displayItem.totpURI != nil ? "Verification code is set up." : "No verification code.")
      ]
      if displayItem.totpURI != nil {
        rows.append(
          AddRowView(title: "Remove Verification Code", symbolName: "minus.circle.fill", tintColor: .systemRed) {
            [weak self] in
            self?.draft?.totpURI = nil
            self?.reloadContent()
          }
        )
      }
      verificationSection.setRows(rows)
    } else {
      let row = VerificationCodeRowView()
      row.configure(totp: displayItem.totp)
      row.onCopy = { code in Pasteboard.copySecret(code) }
      row.onSetUp = { [weak self] in self?.presentVerificationCodeSetup() }
      verificationSection.setRows([row])
    }
  }

  private func configureWebsitesSection(_ displayItem: PasswordItem) {
    if isEditing {
      websitesSection.isHidden = false
      websiteListEditor = EditableListEditor(
        section: websitesSection,
        values: websiteDrafts,
        placeholder: "Website",
        addButtonTitle: "Add Website"
      ) { [weak self] newValues in
        self?.websiteDrafts = newValues
      }
    } else {
      websiteListEditor = nil
      websitesSection.isHidden = displayItem.websites.isEmpty
      let rows: [NSView] = displayItem.websites.map { url in
        let row = WebsiteRowView()
        row.configure(url: url)
        return row
      }
      websitesSection.setRows(rows)
    }
  }

  private func configureNotesSection(_ displayItem: PasswordItem) {
    notesSection.isHidden = !isEditing && displayItem.notes.isEmpty
    let row = NotesRowView(notes: displayItem.notes, isEditing: isEditing)
    row.onValueChange = { [weak self] newValue in
      self?.draft?.notes = newValue
    }
    notesSection.setRows([row])
  }

  private func makeInfoRow(_ text: String) -> NSView {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 13)
    label.textColor = .secondaryLabelColor
    label.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(label)
    NSLayoutConstraint.activate([
      container.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
      label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
      label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
      label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])
    return container
  }

  private func presentVerificationCodeSetup() {
    guard let item, let window = view.window else { return }

    let alert = NSAlert()
    alert.messageText = "Set Up Verification Code"
    alert.informativeText = "Paste the otpauth:// setup URI from your two-factor provider."
    alert.addButton(withTitle: "Add")
    alert.addButton(withTitle: "Cancel")

    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    input.placeholderString = "otpauth://totp/..."
    alert.accessoryView = input

    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self else { return }
      let uri = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !uri.isEmpty, let url = URL(string: uri), (try? OTPAuthURI(url: url)) != nil else {
        self.presentInvalidVerificationCodeAlert()
        return
      }
      var updated = item
      updated.totpURI = uri
      self.vaultViewModel.save(updated)
    }
  }

  private func presentInvalidVerificationCodeAlert() {
    guard let window = view.window else { return }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Invalid Verification Code URI"
    alert.informativeText = "That doesn't look like a valid otpauth:// setup URI."
    alert.addButton(withTitle: "OK")
    alert.beginSheetModal(for: window)
  }
}

/// A plain flipped `NSView`, so the document view inside `scrollView` lays out top-down like
/// everything else in AppKit instead of `NSScrollView`'s default bottom-up coordinate space.
private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}
