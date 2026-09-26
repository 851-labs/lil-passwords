import AppKit
import Combine
import LilPasswordsKit

/// The detail column: shows the selected item — one primary card (icon/title, then User Name,
/// Password, Verification Code, Websites, and Created rows) plus a separate Notes card — or the
/// "nothing selected" empty state, matching Apple Passwords (851-2463).
///
/// Before 851-2463 each of those groups was its own separate rounded card with a leading-aligned
/// header above them; now everything but Notes lives inside one shared card, matching the
/// reference screenshot's single card containing the centered icon/title followed by
/// hairline-divided field rows. Both cards are the same reusable `CardView` (851-2432/#32) the New
/// Password sheet uses, with `identityView` passed in as the primary card's `header` — that gets
/// us the divider under the centered title block for free, the same way `CardView` already
/// dividers every other consecutive pair of rows. The Edit/Cancel/Done control also moved out of
/// this view entirely, into the toolbar (`DetailEditToolbarView`, wired via `editControl` below).
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

  /// 851-2459: cancelled and replaced every `reloadContent()` call so a slow fetch for a
  /// previously-displayed item can never land after the selection has moved on to another one.
  private var iconLoadTask: Task<Void, Never>?

  /// The primary card's rows, assembled by `rebuildPrimaryCard()` from whichever of these pieces
  /// are non-empty right now. Kept as separate arrays/values (rather than recomputing everything
  /// inline in `rebuildPrimaryCard()`) because `EditableListEditor`'s `onRowsChange` needs to
  /// update just its own slice — username or website rows — and trigger a rebuild, independently
  /// of the other groups.
  private var usernameRows: [NSView] = []
  private var passwordRow: NSView?
  private var verificationRows: [NSView] = []
  private var websiteRows: [NSView] = []
  private var createdRow: NSView?

  private let emptyStateView = EmptyStateView()
  private let contentContainer = NSView()
  private let scrollView = NSScrollView()
  private let documentStack = NSStackView()

  private let identityView = DetailIdentityView()
  private let primaryCard = CardView()
  private let notesCard = CardView()

  /// The toolbar's Edit/Cancel/Done control (851-2463): owned and laid out by
  /// `MainToolbarController`, over the detail column. `MainWindowController` hands it over after
  /// constructing both controllers, same pattern as `ItemListViewController.listTitleView`.
  weak var editControl: DetailEditToolbarView? {
    didSet {
      editControl?.onEditTapped = { [weak self] in self?.editTapped() }
      editControl?.onCancelTapped = { [weak self] in self?.cancelTapped() }
      editControl?.onDoneTapped = { [weak self] in self?.doneTapped() }
      updateEditControlState()
    }
  }

  private static let createdDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()

  init(vaultViewModel: VaultViewModel) {
    self.vaultViewModel = vaultViewModel
    super.init(nibName: nil, bundle: nil)
  }

  isolated deinit {
    iconLoadTask?.cancel()
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
      title: String(localized: "No \(singularNoun(for: category)) Selected"),
      message: nil
    )
    emptyStateView.isHidden = false
    contentContainer.isHidden = true
    updateEditControlState()
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

  /// Called by `MainSplitViewController` when the item list's selection contains more than one
  /// item — the detail pane has nothing per-item to show, so it falls back to the empty state.
  func showMultipleSelection(count: Int) {
    itemID = nil
    draft = nil
    websiteDrafts = []
    isEditing = false

    emptyStateView.configure(
      symbolName: "checkmark.circle.fill", title: String(localized: "\(count) Items Selected"), message: nil)
    emptyStateView.isHidden = false
    contentContainer.isHidden = true
    updateEditControlState()
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
    case .all: String(localized: "Password")
    case .passkeys: String(localized: "Passkey")
    case .codes: String(localized: "Code")
    case .wifi: String(localized: "Network")
    case .security: String(localized: "Item")
    case .deleted: String(localized: "Item")
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

    identityView.onTitleChange = { [weak self] newTitle in
      self?.draft?.title = newTitle
    }

    for card in [primaryCard, notesCard] {
      documentStack.addArrangedSubview(card)
      card.widthAnchor.constraint(equalTo: documentStack.widthAnchor, constant: -48).isActive = true
    }

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

  /// Enters edit mode for whichever item is currently shown, if any and not already editing —
  /// the same effect as clicking the toolbar's Edit button. Used by `MainSplitViewController` to
  /// implement "Return to edit" (851-2426): pressing Return on the list's selected row opens it
  /// for editing here, without needing to click Edit.
  func beginEditingCurrentItem() {
    guard !isEditing else { return }
    editTapped()
  }

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
      return trimmed.isEmpty ? String(localized: "Untitled") : trimmed
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

  private func updateEditControlState() {
    editControl?.isEnabled = item != nil
    editControl?.setEditing(isEditing)
  }

  // MARK: Content

  private func reloadContent() {
    guard let displayItem = isEditing ? draft : item else { return }

    iconLoadTask?.cancel()
    identityView.configure(
      title: displayItem.title,
      icon: MonogramIcon.icon(for: displayItem.title, dimension: 64),
      isEditing: isEditing
    )
    let displayItemID = displayItem.id
    iconLoadTask = WebsiteIconLoader.loadIcon(forHost: displayItem.websites.first?.host) { [weak self] icon in
      guard let self, self.itemID == displayItemID else { return }
      self.identityView.setIcon(icon)
    }

    configureUsernameRows(displayItem)
    configurePasswordRow(displayItem)
    configureVerificationRows(displayItem)
    configureWebsiteRows(displayItem)
    createdRow = makeCreatedRow(displayItem)
    rebuildPrimaryCard()

    configureNotesCard(displayItem)
    updateEditControlState()
  }

  /// Assembles the primary card's rows from whichever pieces are currently populated: the
  /// centered identity view as the card's `header`, then User Name(s), Password, Verification
  /// Code, Websites, and finally Created — one shared `CardView`, matching Apple Passwords'
  /// single-card layout (851-2463). Passing `identityView` as `header` rather than as `rows[0]`
  /// (how this worked before adopting `CardView`) is what gets the hairline divider under the
  /// centered title block: `CardView.setContent` dividers between `header` and the first row
  /// exactly the same way it dividers every other consecutive pair.
  private func rebuildPrimaryCard() {
    var rows: [NSView] = []
    rows.append(contentsOf: usernameRows)
    if let passwordRow {
      rows.append(passwordRow)
    }
    rows.append(contentsOf: verificationRows)
    rows.append(contentsOf: websiteRows)
    if let createdRow {
      rows.append(createdRow)
    }
    primaryCard.setContent(header: identityView, rows: rows)
  }

  private func configureUsernameRows(_ displayItem: PasswordItem) {
    if isEditing {
      usernameListEditor = EditableListEditor(
        values: displayItem.usernames,
        placeholder: String(localized: "Username or Email"),
        addButtonTitle: String(localized: "Add Username"),
        onChange: { [weak self] newValues in
          self?.draft?.usernames = newValues
        },
        onRowsChange: { [weak self] rows in
          self?.usernameRows = rows
          self?.rebuildPrimaryCard()
        }
      )
    } else {
      usernameListEditor = nil
      // Apple Passwords labels only the first row when there's more than one username (using
      // the plural "User Names"), leaving the rest unlabeled rather than repeating the label.
      let label = displayItem.usernames.count > 1 ? String(localized: "User Names") : String(localized: "User Name")
      usernameRows = displayItem.usernames.enumerated().map { index, username in
        let row = DetailValueRowView()
        row.configure(label: index == 0 ? label : "", value: username)
        row.onCopy = { Pasteboard.copySecret(username) }
        return row
      }
    }
  }

  private func configurePasswordRow(_ displayItem: PasswordItem) {
    if isEditing {
      let row = PasswordEditRowView(value: displayItem.password)
      row.onValueChange = { [weak self] newValue in
        self?.draft?.password = newValue
      }
      passwordRow = row
    } else {
      let row = PasswordRowView()
      row.configure(password: displayItem.password)
      row.onCopy = { Pasteboard.copySecret(displayItem.password) }
      passwordRow = row
    }
  }

  private func configureVerificationRows(_ displayItem: PasswordItem) {
    if isEditing {
      var rows: [NSView] = [
        makeInfoRow(
          displayItem.totpURI != nil
            ? String(localized: "Verification code is set up.") : String(localized: "No verification code."))
      ]
      if displayItem.totpURI != nil {
        rows.append(
          AddRowView(
            title: String(localized: "Remove Verification Code"), symbolName: "minus.circle.fill",
            tintColor: .systemRed
          ) {
            [weak self] in
            self?.draft?.totpURI = nil
            self?.reloadContent()
          }
        )
      }
      verificationRows = rows
    } else {
      let row = VerificationCodeRowView()
      row.configure(totp: displayItem.totp)
      row.onCopy = { code in Pasteboard.copySecret(code) }
      row.onSetUp = { [weak self] in self?.presentVerificationCodeSetup() }
      verificationRows = [row]
    }
  }

  private func configureWebsiteRows(_ displayItem: PasswordItem) {
    if isEditing {
      websiteListEditor = EditableListEditor(
        values: websiteDrafts,
        placeholder: String(localized: "Website"),
        addButtonTitle: String(localized: "Add Website"),
        onChange: { [weak self] newValues in
          self?.websiteDrafts = newValues
        },
        onRowsChange: { [weak self] rows in
          self?.websiteRows = rows
          self?.rebuildPrimaryCard()
        }
      )
    } else {
      websiteListEditor = nil
      websiteRows = displayItem.websites.map { url in
        let row = WebsiteRowView()
        row.configure(url: url)
        return row
      }
    }
  }

  /// A plain read-only row — unlike User Name/Password, "Created" is never copyable or editable,
  /// so it doesn't need `DetailValueRowView`'s hover-to-reveal copy button. That makes it a
  /// straightforward `KeyValueRow` (851-2432/#32): a right-aligned label as `value`, no accessory.
  private func makeCreatedRow(_ displayItem: PasswordItem) -> NSView {
    let valueField = NSTextField(labelWithString: Self.createdDateFormatter.string(from: displayItem.createdAt))
    valueField.font = .systemFont(ofSize: 13)
    valueField.textColor = .secondaryLabelColor
    valueField.alignment = .right
    valueField.lineBreakMode = .byTruncatingMiddle
    return KeyValueRow(label: String(localized: "Created"), value: valueField)
  }

  private func configureNotesCard(_ displayItem: PasswordItem) {
    notesCard.isHidden = !isEditing && displayItem.notes.isEmpty
    let row = NotesRowView(notes: displayItem.notes, isEditing: isEditing)
    row.onValueChange = { [weak self] newValue in
      self?.draft?.notes = newValue
    }
    notesCard.setContent(rows: [row])
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
      // 16pt/-16pt, matching every other row's inset (see `DetailValueRowView`'s comment) now that
      // this card is a `CardView` with 16pt-inset dividers.
      label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
      label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
      label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])
    return container
  }

  private func presentVerificationCodeSetup() {
    guard let item, let window = view.window else { return }

    let alert = NSAlert()
    alert.messageText = String(localized: "Set Up Verification Code")
    alert.informativeText = String(localized: "Paste the otpauth:// setup URI from your two-factor provider.")
    alert.addButton(withTitle: String(localized: "Add"))
    alert.addButton(withTitle: String(localized: "Cancel"))

    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    input.placeholderString = String(localized: "otpauth://totp/...")
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
    alert.messageText = String(localized: "Invalid Verification Code URI")
    alert.informativeText = String(localized: "That doesn't look like a valid otpauth:// setup URI.")
    alert.addButton(withTitle: String(localized: "OK"))
    alert.beginSheetModal(for: window)
  }
}

/// A plain flipped `NSView`, so the document view inside `scrollView` lays out top-down like
/// everything else in AppKit instead of `NSScrollView`'s default bottom-up coordinate space.
private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}
