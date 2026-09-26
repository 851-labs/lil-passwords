import AppKit
import LilPasswordsKit

/// Presents the "New Password" sheet: one inset rounded ``CardView`` — a centered icon and large
/// bold Title, then User Name / Password / Website / Notes rows — plus Cancel/Save below it,
/// matching Apple Passwords' own New Password sheet (851-2416).
@MainActor
final class NewPasswordSheetController: NSWindowController {
  enum Outcome {
    /// The item was saved through the vault. Callers typically select it in the item list.
    case saved(PasswordItem)
    /// The sheet was dismissed (Cancel, or the window closing) without saving anything.
    case cancelled
  }

  private static let iconDimension: CGFloat = 64

  private let vaultViewModel: any VaultViewModel
  private let generator = PasswordGenerator()
  private var passwordFormat: PasswordGenerator.Format = .appleStrong
  private var completion: ((Outcome) -> Void)?
  private var didFinish = false

  private var iconView: NSImageView!
  private var titleField: NSTextField!
  private var usernameField: NSTextField!
  private var passwordValueView: PasswordCardValueView!
  private var websiteField: NSTextField!
  private var notesTextView: NSTextView!
  private var saveButton: NSButton!

  private init(vaultViewModel: any VaultViewModel) {
    self.vaultViewModel = vaultViewModel
    let window = NSWindow(
      contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    window.title = "New Password"
    // Apple Passwords' own New Password sheet has no visible title bar at all — the card sits
    // flush with the sheet's own rounded corners. `.fullSizeContentView` plus hiding the title
    // (rather than dropping `.titled` entirely) keeps the window's title bar *metadata* (visible
    // in the Window menu, VoiceOver, etc.) without drawing anything for it.
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.standardWindowButton(.closeButton)?.isHidden = true
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true
    super.init(window: window)
    buildContent()
    regeneratePassword()
    updateIcon()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Presents the sheet over `parentWindow`. `completion` fires exactly once, with `.cancelled`
  /// if the user backs out without saving.
  static func present(
    vaultViewModel: any VaultViewModel,
    from parentWindow: NSWindow,
    completion: @escaping (Outcome) -> Void
  ) {
    let controller = NewPasswordSheetController(vaultViewModel: vaultViewModel)
    controller.completion = completion
    guard let sheetWindow = controller.window else {
      completion(.cancelled)
      return
    }
    // The sheet's completion handler is the only strong reference keeping `controller` (and
    // therefore its window) alive; `beginSheet` retains this closure for the sheet's lifetime.
    parentWindow.beginSheet(sheetWindow) { _ in
      withExtendedLifetime(controller) {}
    }
  }

  // MARK: - Layout

  private func buildContent() {
    let icon = NSImageView()
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.translatesAutoresizingMaskIntoConstraints = false
    iconView = icon

    let title = NSTextField()
    title.placeholderString = "Title"
    title.font = .boldSystemFont(ofSize: 26)
    title.alignment = .center
    title.isBordered = false
    title.drawsBackground = false
    title.delegate = self
    titleField = title

    let header = NSStackView(views: [icon, title])
    header.orientation = .vertical
    header.alignment = .centerX
    header.spacing = 12
    header.edgeInsets = NSEdgeInsets(top: 24, left: 16, bottom: 20, right: 16)
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: Self.iconDimension),
      icon.heightAnchor.constraint(equalToConstant: Self.iconDimension),
      title.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
    ])

    let username = valueField(placeholder: "user")
    usernameField = username
    let usernameRow = KeyValueRow(label: "User Name", value: username)

    let regenerateButton = NSButton(
      image: NSImage(systemSymbolName: "arrow.clockwise.circle", accessibilityDescription: "Password Options")
        ?? NSImage(),
      target: self,
      action: #selector(showPasswordMenu(_:))
    )
    regenerateButton.isBordered = false
    regenerateButton.imagePosition = .imageOnly
    regenerateButton.contentTintColor = .secondaryLabelColor
    // `accessory` here, not `KeyValueRow`'s own accessory slot: see `PasswordCardValueView`'s
    // documentation for why (851-2416 review — that slot was silently shrinking the value column,
    // pulling the dots' right edge in from where every other row's value lines up).
    let passwordValue = PasswordCardValueView(value: "", accessory: regenerateButton)
    passwordValueView = passwordValue
    let passwordRow = KeyValueRow(label: "Password", value: passwordValue)

    let website = valueField(placeholder: "example.com")
    websiteField = website
    website.delegate = self
    let websiteRow = KeyValueRow(label: "Website", value: website)

    let notesView = NSTextView()
    notesView.font = .systemFont(ofSize: 13)
    notesView.isRichText = false
    notesView.drawsBackground = false
    notesView.textContainerInset = .zero
    notesView.textContainer?.lineFragmentPadding = 0
    notesTextView = notesView
    let notesScrollView = NSScrollView()
    notesScrollView.documentView = notesView
    notesScrollView.drawsBackground = false
    notesScrollView.hasVerticalScroller = true
    notesScrollView.translatesAutoresizingMaskIntoConstraints = false
    notesScrollView.heightAnchor.constraint(equalToConstant: 54).isActive = true
    let notesRow = KeyValueRow(label: "Notes", value: notesScrollView, stacked: true)

    let card = CardView()
    card.setContent(header: header, rows: [usernameRow, passwordRow, websiteRow, notesRow])

    let footerDivider = NSBox()
    footerDivider.boxType = .separator

    let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
    cancelButton.bezelStyle = .rounded
    cancelButton.keyEquivalent = "\u{1b}"
    let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
    save.bezelStyle = .rounded
    save.keyEquivalent = "\r"
    saveButton = save

    let spacer = NSView()
    spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    let footerRow = NSStackView(views: [cancelButton, spacer, save])
    footerRow.orientation = .horizontal
    footerRow.spacing = 8

    let container = NSView()
    for view in [card, footerDivider, footerRow] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(view)
    }

    NSLayoutConstraint.activate([
      card.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
      card.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
      card.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

      // The divider above Cancel/Save runs the sheet's full width, edge to edge — unlike the
      // card's own internal row dividers, which stop short of the card's rounded corners.
      footerDivider.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 20),
      footerDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      footerDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      footerDivider.heightAnchor.constraint(equalToConstant: 1),

      footerRow.topAnchor.constraint(equalTo: footerDivider.bottomAnchor, constant: 16),
      footerRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
      footerRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
      footerRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
    ])

    window?.contentView = container

    // The sheet's height is derived from its actual content, not a guessed constant: every row
    // above is a fixed 40pt and the header's height comes from its own intrinsic content, so
    // `container` has exactly one natural height for a given width. A hardcoded
    // `setContentSize` here previously guessed a height taller than that natural content, and
    // since the fixed-height rows below have nowhere left to absorb the extra space, `header` —
    // the one arranged view in the card without a hard-pinned height — silently stretched to eat
    // all of it, pushing "User Name" far down from "Title". Measuring the real fitting size
    // avoids reintroducing that by construction.
    let width: CGFloat = 460
    let widthConstraint = container.widthAnchor.constraint(equalToConstant: width)
    widthConstraint.isActive = true
    let fittingHeight = container.fittingSize.height
    window?.setContentSize(NSSize(width: width, height: fittingHeight))
    updateSaveEnabled()
  }

  /// A bezel-less, right-aligned value field for an inline ``KeyValueRow`` — "User Name" and
  /// "Website" both use this; "Password" uses ``PasswordCardValueView`` instead since it needs
  /// mask/reveal behavior this plain field doesn't.
  private func valueField(placeholder: String) -> NSTextField {
    let field = NSTextField()
    field.placeholderString = placeholder
    field.font = .systemFont(ofSize: 13)
    field.textColor = .secondaryLabelColor
    field.alignment = .right
    field.isBordered = false
    field.drawsBackground = false
    field.lineBreakMode = .byTruncatingMiddle
    return field
  }

  // MARK: - Icon

  /// Shows the app icon until a title or website is typed, then switches to the monogram for
  /// whatever title `makeItem()` would currently resolve to — matching Apple Passwords, which
  /// shows a per-item icon (here, the monogram, since there's no favicon fetch for an unsaved
  /// item) once there's something to base it on.
  private func updateIcon() {
    let effectiveTitle = resolvedTitle()
    iconView.image =
      effectiveTitle.isEmpty
      ? NSApplication.shared.applicationIconImage
      : MonogramIcon.icon(for: effectiveTitle, dimension: Self.iconDimension)
  }

  private func resolvedTitle() -> String {
    let trimmedTitle = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedTitle.isEmpty { return trimmedTitle }
    return Self.parseWebsite(websiteField.stringValue)?.host ?? ""
  }

  // MARK: - Password generation

  @objc
  private func showPasswordMenu(_ sender: NSButton) {
    let menu = NSMenu()
    menu.addItem(withTitle: "Regenerate Password", action: #selector(regenerateTapped), keyEquivalent: "")

    let noSymbols = menu.addItem(
      withTitle: "No Special Characters", action: #selector(toggleNoSpecialCharacters), keyEquivalent: "")
    noSymbols.state = isNoSpecialCharacters ? .on : .off

    for item in menu.items {
      item.target = self
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
  }

  private var isNoSpecialCharacters: Bool {
    if case .custom = passwordFormat { return true }
    return false
  }

  @objc
  private func regenerateTapped() {
    regeneratePassword()
  }

  @objc
  private func toggleNoSpecialCharacters() {
    passwordFormat =
      isNoSpecialCharacters
      ? .appleStrong
      : .custom(length: AppSettings.shared.defaultPasswordLength, characterCategories: .noSymbols)
    regeneratePassword()
  }

  private func regeneratePassword() {
    passwordValueView.setValue((try? generator.generate(format: passwordFormat)) ?? "")
  }

  // MARK: - Save / Cancel

  @objc
  private func cancelTapped() {
    finish(outcome: .cancelled)
  }

  @objc
  private func saveTapped() {
    let item = makeItem()
    // `VaultViewModel.save(_:)` is synchronous/fire-and-forget (it kicks off its own `Task`
    // against the underlying `VaultStoring`, same as an edit-mode save from the detail pane) —
    // there's nothing to await, and no per-save error to surface here; a persistence failure
    // there already trips `assertionFailure` rather than something this sheet could recover from.
    vaultViewModel.save(item)
    finish(outcome: .saved(item))
  }

  private func makeItem() -> PasswordItem {
    let websiteURL = Self.parseWebsite(websiteField.stringValue)
    let trimmedUsername = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedWebsite = websiteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedTitle = resolvedTitle()

    return PasswordItem(
      title: resolvedTitle.isEmpty ? trimmedWebsite : resolvedTitle,
      usernames: trimmedUsername.isEmpty ? [] : [trimmedUsername],
      password: passwordValueView.stringValue,
      websites: websiteURL.map { [$0] } ?? [],
      notes: notesTextView.string
    )
  }

  /// Normalizes a raw, user-typed website string into a `URL`: adds an `https://` scheme if one
  /// wasn't typed, and returns `nil` for blank input. There's no shared "parse a loose website
  /// string" helper in `LilPasswordsKit` today (`PasswordItemSchema` validates already-structured
  /// import data, not free-typed UI input), so this stays local to the sheet that needs it.
  private static func parseWebsite(_ raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.contains("://") {
      return URL(string: trimmed)
    }
    return URL(string: "https://\(trimmed)")
  }

  private func updateSaveEnabled() {
    let hasTitle = !titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasWebsite = !websiteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    saveButton.isEnabled = hasTitle || hasWebsite
  }

  private func finish(outcome: Outcome) {
    guard let window, !didFinish else { return }
    didFinish = true
    if let sheetParent = window.sheetParent {
      sheetParent.endSheet(window)
    } else {
      window.close()
    }
    completion?(outcome)
  }
}

extension NewPasswordSheetController: NSTextFieldDelegate {
  func controlTextDidChange(_ notification: Notification) {
    updateSaveEnabled()
    updateIcon()
  }
}
