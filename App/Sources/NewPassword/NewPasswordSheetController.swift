import AppKit
import LilPasswordsKit

/// Presents the "New Password" sheet: Title, Website, User Name, a generated Password (with a
/// menu to regenerate or switch to "No Special Characters"), and Notes — matching Apple
/// Passwords' own New Password sheet (851-2416).
@MainActor
final class NewPasswordSheetController: NSWindowController {
  enum Outcome {
    /// The item was saved through the vault. Callers typically select it in the item list.
    case saved(PasswordItem)
    /// The sheet was dismissed (Cancel, or the window closing) without saving anything.
    case cancelled
  }

  private let vaultViewModel: any VaultViewModel
  private let generator = PasswordGenerator()
  private var passwordFormat: PasswordGenerator.Format = .appleStrong
  private var completion: ((Outcome) -> Void)?
  private var didFinish = false

  private var titleField: NSTextField!
  private var websiteField: NSTextField!
  private var usernameField: NSTextField!
  private var passwordField: NSTextField!
  private var notesTextView: NSTextView!
  private var saveButton: NSButton!
  private var passwordOptionsButton: NSButton!

  private init(vaultViewModel: any VaultViewModel) {
    self.vaultViewModel = vaultViewModel
    let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "New Password"
    super.init(window: window)
    buildContent()
    regeneratePassword()
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
    let titleHeading = NSTextField(labelWithString: "New Password")
    titleHeading.font = .boldSystemFont(ofSize: 15)

    let title = labeledField(placeholder: "Title")
    titleField = title
    title.delegate = self

    let website = labeledField(placeholder: "example.com")
    websiteField = website
    website.delegate = self

    let username = labeledField(placeholder: "User Name")
    usernameField = username

    let password = NSTextField()
    password.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    passwordField = password

    let optionsButton = NSButton(
      image: NSImage(systemSymbolName: "arrow.clockwise.circle", accessibilityDescription: "Password Options")
        ?? NSImage(),
      target: self,
      action: #selector(showPasswordMenu(_:))
    )
    optionsButton.bezelStyle = .texturedRounded
    optionsButton.isBordered = false
    optionsButton.imagePosition = .imageOnly
    passwordOptionsButton = optionsButton

    let passwordRow = NSStackView(views: [password, optionsButton])
    passwordRow.orientation = .horizontal
    passwordRow.spacing = 6
    password.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

    let notesScrollView = NSScrollView()
    notesScrollView.hasVerticalScroller = true
    notesScrollView.borderType = .bezelBorder
    let notesView = NSTextView()
    notesView.font = .systemFont(ofSize: 13)
    notesView.isEditable = true
    notesView.isRichText = false
    notesScrollView.documentView = notesView
    notesTextView = notesView

    let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
    cancelButton.keyEquivalent = "\u{1b}"
    let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
    save.keyEquivalent = "\r"
    saveButton = save

    let spacer = NSView()
    spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    let footerRow = NSStackView(views: [cancelButton, spacer, save])
    footerRow.orientation = .horizontal
    footerRow.spacing = 8

    let stack = NSStackView(views: [
      titleHeading,
      formRow(label: "Title", field: title),
      formRow(label: "Website", field: website),
      formRow(label: "User Name", field: username),
      formRow(label: "Password", field: passwordRow),
      formRow(label: "Notes", field: notesScrollView),
      footerRow,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    stack.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      footerRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
      notesScrollView.heightAnchor.constraint(equalToConstant: 70),
    ])

    window?.contentView = container
    window?.setContentSize(NSSize(width: 420, height: 430))
    updateSaveEnabled()
  }

  /// A label above a field/control, at a fixed row width so every row's control lines up under
  /// the previous one despite different label lengths.
  private func formRow(label: String, field: NSView) -> NSView {
    let labelField = NSTextField(labelWithString: label)
    labelField.font = .systemFont(ofSize: 11)
    labelField.textColor = .secondaryLabelColor

    field.translatesAutoresizingMaskIntoConstraints = false
    let row = NSStackView(views: [labelField, field])
    row.orientation = .vertical
    row.alignment = .leading
    row.spacing = 4
    NSLayoutConstraint.activate([field.widthAnchor.constraint(equalToConstant: 340)])
    return row
  }

  private func labeledField(placeholder: String) -> NSTextField {
    let field = NSTextField()
    field.placeholderString = placeholder
    return field
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
    passwordField.stringValue = (try? generator.generate(format: passwordFormat)) ?? ""
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
    let trimmedTitle = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let websiteURL = Self.parseWebsite(websiteField.stringValue)
    let trimmedUsername = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

    let resolvedTitle: String =
      !trimmedTitle.isEmpty
      ? trimmedTitle
      : (websiteURL?.host ?? websiteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))

    return PasswordItem(
      title: resolvedTitle,
      usernames: trimmedUsername.isEmpty ? [] : [trimmedUsername],
      password: passwordField.stringValue,
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
  }
}
