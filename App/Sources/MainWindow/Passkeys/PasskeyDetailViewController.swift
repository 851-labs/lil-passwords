import AppKit
import LilPasswordsKit

/// The Passkeys category's detail column: the selected passkey's website, user name, created
/// date, and a Delete button — matching the ticket's "the detail card shows the website, user
/// name, created date, and Delete button." Never shows a sign count, credential ID, or any key
/// material: ``PasskeyMetadata`` structurally can't carry those (see its own doc comment).
///
/// Modeled on ``WiFiDetailViewController`` (851-2444's rework to match 851-2463's Apple-parity
/// chrome): a `CardView` with a centered `DetailIdentityView` header plus `KeyValueRow`s, top-
/// aligned under the toolbar, non-editable throughout — unlike a `PasswordItem`, none of a
/// passkey's fields are ever typed in or edited here; they either came from the relying party at
/// registration time or don't apply. The one interactive row is the destructive "Delete Passkey"
/// row (``AddRowView``, red), which goes through the same confirmation
/// (``PasskeyDeleteConfirmation``) the list's Delete key/context menu uses.
@MainActor
final class PasskeyDetailViewController: NSViewController {
  private let viewModel: PasskeysViewModel
  private var passkey: PasskeyMetadata?

  private let emptyStateView = EmptyStateView()
  private let contentContainer = NSView()
  private let scrollView = NSScrollView()
  private let contentStack = NSStackView()
  private let identityView = DetailIdentityView()
  private let cardView = CardView()
  private let websiteValueField = NSTextField(labelWithString: "")
  private let userNameValueField = NSTextField(labelWithString: "")
  private let createdValueField = NSTextField(labelWithString: "")

  /// Cancelled on every `show(passkey:)` call and in `viewDidDisappear`-adjacent teardown isn't
  /// needed here (unlike `CredentialRowView`, this view is never recycled) — but a fetch for a
  /// passkey the person has since deselected must still never land, so this is cancelled and
  /// replaced the same way `CredentialRowView.iconLoadTask` is.
  private var iconLoadTask: Task<Void, Never>?

  init(viewModel: PasskeysViewModel) {
    self.viewModel = viewModel
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func loadView() {
    let view = NSView()

    emptyStateView.translatesAutoresizingMaskIntoConstraints = false
    emptyStateView.configure(
      symbolName: SidebarCategory.passkeys.symbolName,
      title: String(localized: "No Passkey Selected"),
      message: String(localized: "Select a passkey to see its details.")
    )

    configureContentContainer(in: view)

    view.addSubview(emptyStateView)
    NSLayoutConstraint.activate([
      emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      emptyStateView.topAnchor.constraint(equalTo: view.topAnchor),
      emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    self.view = view
    showNoSelection()
  }

  private func configureContentContainer(in view: NSView) {
    contentContainer.translatesAutoresizingMaskIntoConstraints = false
    contentContainer.isHidden = true
    view.addSubview(contentContainer)
    NSLayoutConstraint.activate([
      contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      // `safeAreaLayoutGuide`, not `view.topAnchor` — matches `WiFiDetailViewController`/
      // `DetailViewController`: keeps the card top-aligned just under the unified toolbar.
      contentContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    configureContentStack()

    let flippedDocumentView = FlippedView()
    flippedDocumentView.translatesAutoresizingMaskIntoConstraints = false
    flippedDocumentView.addSubview(contentStack)
    NSLayoutConstraint.activate([
      contentStack.leadingAnchor.constraint(equalTo: flippedDocumentView.leadingAnchor),
      contentStack.trailingAnchor.constraint(equalTo: flippedDocumentView.trailingAnchor),
      contentStack.topAnchor.constraint(equalTo: flippedDocumentView.topAnchor),
      contentStack.bottomAnchor.constraint(equalTo: flippedDocumentView.bottomAnchor),
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

  private func configureContentStack() {
    contentStack.orientation = .vertical
    contentStack.alignment = .leading
    contentStack.spacing = 20
    // Matches `DetailViewController`/`WiFiDetailViewController`'s card insets.
    contentStack.edgeInsets = NSEdgeInsets(top: 8, left: 24, bottom: 24, right: 24)
    contentStack.translatesAutoresizingMaskIntoConstraints = false

    websiteValueField.font = .systemFont(ofSize: 13)
    websiteValueField.textColor = .secondaryLabelColor
    websiteValueField.alignment = .right
    websiteValueField.lineBreakMode = .byTruncatingMiddle
    let websiteRow = KeyValueRow(label: String(localized: "Website"), value: websiteValueField)

    userNameValueField.font = .systemFont(ofSize: 13)
    userNameValueField.textColor = .secondaryLabelColor
    userNameValueField.alignment = .right
    userNameValueField.lineBreakMode = .byTruncatingMiddle
    let userNameRow = KeyValueRow(label: String(localized: "User Name"), value: userNameValueField)

    createdValueField.font = .systemFont(ofSize: 13)
    createdValueField.textColor = .secondaryLabelColor
    createdValueField.alignment = .right
    let createdRow = KeyValueRow(label: String(localized: "Created"), value: createdValueField)

    // The one interactive, destructive row — matches `DetailViewController`'s "Remove
    // Verification Code" `AddRowView` styling (red minus-circle), reads `self.passkey` at tap
    // time (not captured up front), same as `WiFiDetailViewController.showQRCodeTapped()`.
    let deleteRow = AddRowView(
      title: String(localized: "Delete Passkey"),
      symbolName: "minus.circle.fill",
      tintColor: .systemRed,
      action: { [weak self] in self?.deleteTapped() }
    )

    cardView.setContent(header: identityView, rows: [websiteRow, userNameRow, createdRow, deleteRow])

    contentStack.addArrangedSubview(cardView)
    // Matches `DetailViewController`/`WiFiDetailViewController`'s card-width pattern.
    cardView.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -48).isActive = true
  }

  func show(passkey: PasskeyMetadata?) {
    self.passkey = passkey
    iconLoadTask?.cancel()

    guard let passkey else {
      showNoSelection()
      return
    }

    emptyStateView.isHidden = true
    contentContainer.isHidden = false

    let title = PasskeysViewModel.title(for: passkey)
    identityView.configure(title: title, icon: MonogramIcon.icon(for: title, dimension: 64), isEditing: false)
    iconLoadTask = WebsiteIconLoader.loadIcon(forHost: passkey.website?.host, dimension: 64) { [weak self] icon in
      self?.identityView.setIcon(icon)
    }

    websiteValueField.stringValue = passkey.website?.host ?? passkey.relyingPartyIdentifier
    userNameValueField.stringValue = passkey.displayName
    createdValueField.stringValue = Self.dateFormatter.string(from: passkey.createdAt)

    view.setAccessibilityLabel(String(localized: "\(title), \(passkey.displayName)"))
  }

  private func showNoSelection() {
    emptyStateView.isHidden = false
    contentContainer.isHidden = true
    view.setAccessibilityLabel(nil)
  }

  private func deleteTapped() {
    guard let passkey, let window = view.window else { return }
    PasskeyDeleteConfirmation.present(passkey, from: window) { [weak self] in
      try await self?.viewModel.delete(id: passkey.id)
      // A successful delete clears this column back to its empty state — `viewModel.delete(id:)`
      // already refreshed the list, but this column doesn't observe `$passkeys` directly (it's
      // driven by `MainSplitViewController`'s selection-forwarding, same as `DetailViewController`),
      // so it has to clear itself rather than waiting on a selection-changed callback that won't
      // come once the row it was showing no longer exists.
      await MainActor.run { self?.show(passkey: nil) }
    }
  }

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()
}
