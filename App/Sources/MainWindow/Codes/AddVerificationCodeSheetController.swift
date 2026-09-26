import AppKit
import LilPasswordsKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Presents the "Add Verification Code" sheet (851-2418): pick which item the code belongs to,
/// then attach it via a typed-in setup key, an imported QR code image, or a QR code detected
/// on-screen — matching Apple Passwords' "Set Up Verification Code" flow.
///
/// A single window whose content view is swapped between three simple, freshly-built steps
/// (`showPickItemStep()` → `showChooseMethodStep(for:)` → `showSetupKeyStep(for:)`) rather than
/// three separate view controllers — this sheet is shown rarely and each step is small, so
/// rebuilding on transition keeps the state machine easy to follow.
@MainActor
final class AddVerificationCodeSheetController: NSWindowController {
  enum Outcome {
    /// `item` was saved with a new `totpURI`.
    case saved(PasswordItem)
    /// The sheet was dismissed without adding a code.
    case cancelled
  }

  private enum CaptureError: Swift.Error {
    case noDisplay
    case captureFailed
    case noCodeFound
  }

  private let dataSource: VaultViewModel
  private var completion: ((Outcome) -> Void)?
  private var didFinish = false

  // Pick-item step state.
  private var allItems: [PasswordItem] = []
  private var filteredItems: [PasswordItem] = []
  private var itemsTableView: NSTableView?
  private var continueButton: NSButton?

  // Setup-key step state.
  private var secretField: NSTextField?
  private var issuerField: NSTextField?
  private var accountField: NSTextField?
  private var keyErrorLabel: NSTextField?
  private var addButton: NSButton?

  private var pendingItem: PasswordItem?

  private init(dataSource: VaultViewModel) {
    self.dataSource = dataSource
    let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Add Verification Code"
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Presents the sheet over `parentWindow`. `completion` fires exactly once, with `.cancelled` if
  /// the user backs out before a code is successfully attached to an item.
  static func present(
    dataSource: VaultViewModel,
    from parentWindow: NSWindow,
    completion: @escaping (Outcome) -> Void
  ) {
    let controller = AddVerificationCodeSheetController(dataSource: dataSource)
    controller.completion = completion
    guard let sheetWindow = controller.window else {
      completion(.cancelled)
      return
    }
    controller.allItems = dataSource.items.nonDeleted().sorted(
      by: PasswordItem.sortComparator(for: .title, direction: .ascending))
    controller.filteredItems = controller.allItems
    controller.showPickItemStep()
    // The sheet's completion handler is the only strong reference keeping `controller` (and
    // therefore its window) alive; `beginSheet` retains this closure for the sheet's lifetime.
    parentWindow.beginSheet(sheetWindow) { _ in
      withExtendedLifetime(controller) {}
    }
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

  // MARK: - Step 1: pick an item

  private func showPickItemStep() {
    itemsTableView = nil
    continueButton = nil

    let titleField = NSTextField(labelWithString: "Add Verification Code")
    titleField.font = .boldSystemFont(ofSize: 15)

    let subtitleField = NSTextField(wrappingLabelWithString: "Choose which item this verification code belongs to.")
    subtitleField.font = .systemFont(ofSize: 12)
    subtitleField.textColor = .secondaryLabelColor

    let searchField = NSSearchField()
    searchField.placeholderString = "Search"
    searchField.delegate = self

    let tableView = NSTableView()
    tableView.headerView = nil
    tableView.usesAlternatingRowBackgroundColors = false
    tableView.allowsMultipleSelection = false
    tableView.dataSource = self
    tableView.delegate = self
    tableView.style = .plain
    tableView.rowHeight = 40
    tableView.target = self
    tableView.doubleAction = #selector(continueTapped)
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("PickItemColumn"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)
    itemsTableView = tableView

    let scrollView = NSScrollView()
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .bezelBorder
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
    let next = NSButton(title: "Continue", target: self, action: #selector(continueTapped))
    next.keyEquivalent = "\r"
    next.isEnabled = false
    continueButton = next

    let spacer = NSView()
    spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    let footerRow = NSStackView(views: [cancelButton, spacer, next])
    footerRow.orientation = .horizontal
    footerRow.spacing = 8

    let stack = NSStackView(views: [titleField, subtitleField, searchField, scrollView, footerRow])
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
      subtitleField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
      searchField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
      scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
      scrollView.heightAnchor.constraint(equalToConstant: 220),
      footerRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
    ])

    window?.title = "Add Verification Code"
    window?.contentView = container
    window?.setContentSize(NSSize(width: 440, height: 420))
    tableView.reloadData()
  }

  @objc
  private func cancelTapped() {
    finish(outcome: .cancelled)
  }

  @objc
  private func continueTapped() {
    guard let tableView = itemsTableView, tableView.selectedRow >= 0,
      filteredItems.indices.contains(tableView.selectedRow)
    else { return }
    let item = filteredItems[tableView.selectedRow]
    pendingItem = item
    showChooseMethodStep(for: item)
  }

  // MARK: - Step 2: choose a method

  private func showChooseMethodStep(for item: PasswordItem) {
    let backButton = NSButton(
      image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back") ?? NSImage(),
      target: self, action: #selector(backToPickItem))
    backButton.isBordered = false

    let titleField = NSTextField(labelWithString: "Add Code for \(item.title)")
    titleField.font = .boldSystemFont(ofSize: 15)

    let subtitleField = NSTextField(wrappingLabelWithString: "How would you like to add this verification code?")
    subtitleField.font = .systemFont(ofSize: 12)
    subtitleField.textColor = .secondaryLabelColor

    let setupKeyButton = methodButton(
      symbolName: "key.fill",
      title: "Enter Setup Key",
      subtitle: "Type in a code manually",
      action: #selector(chooseSetupKey)
    )
    let qrFileButton = methodButton(
      symbolName: "photo",
      title: "Choose QR Image File…",
      subtitle: "Import a QR code from an image",
      action: #selector(chooseQRImageFile)
    )
    let scanButton = methodButton(
      symbolName: "display",
      title: "Scan Screen for QR Code",
      subtitle: "Detect a QR code currently on screen",
      action: #selector(chooseScanScreen)
    )

    let methodsStack = NSStackView(views: [setupKeyButton, qrFileButton, scanButton])
    methodsStack.orientation = .vertical
    methodsStack.alignment = .leading
    methodsStack.spacing = 10

    let headerRow = NSStackView(views: [backButton, titleField])
    headerRow.orientation = .horizontal
    headerRow.spacing = 8

    let stack = NSStackView(views: [headerRow, subtitleField, methodsStack])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 16
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    stack.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      subtitleField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
      methodsStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
    ])

    window?.contentView = container
    window?.setContentSize(NSSize(width: 440, height: 320))
  }

  private func methodButton(symbolName: String, title: String, subtitle: String, action: Selector) -> NSButton {
    let button = NSButton(title: "", target: self, action: action)
    button.bezelStyle = .rounded
    button.controlSize = .large
    button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    button.imagePosition = .imageLeading
    button.title = "  \(title)"
    button.font = .systemFont(ofSize: 13)
    button.toolTip = subtitle
    button.translatesAutoresizingMaskIntoConstraints = false
    button.contentTintColor = .controlAccentColor
    button.widthAnchor.constraint(equalToConstant: 380).isActive = true
    button.heightAnchor.constraint(equalToConstant: 36).isActive = true
    return button
  }

  @objc
  private func backToPickItem() {
    showPickItemStep()
  }

  // MARK: - Step 3a: setup key

  @objc
  private func chooseSetupKey() {
    guard let item = pendingItem else { return }
    showSetupKeyStep(for: item)
  }

  private func showSetupKeyStep(for item: PasswordItem) {
    let backButton = NSButton(
      image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back") ?? NSImage(),
      target: self, action: #selector(backToChooseMethod))
    backButton.isBordered = false

    let titleField = NSTextField(labelWithString: "Enter Setup Key")
    titleField.font = .boldSystemFont(ofSize: 15)

    let secret = NSTextField()
    secret.placeholderString = "Setup Key"
    secret.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    secret.delegate = self
    secretField = secret

    let issuer = NSTextField(string: item.title)
    issuer.placeholderString = "Issuer (e.g. GitHub)"
    issuerField = issuer

    let account = NSTextField(string: item.usernames.first(where: { !$0.isEmpty }) ?? "")
    account.placeholderString = "Account Name"
    accountField = account

    let error = NSTextField(labelWithString: "")
    error.font = .systemFont(ofSize: 11)
    error.textColor = .systemRed
    error.maximumNumberOfLines = 2
    error.isHidden = true
    keyErrorLabel = error

    let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
    let add = NSButton(title: "Add", target: self, action: #selector(addSetupKeyTapped))
    add.keyEquivalent = "\r"
    add.isEnabled = false
    addButton = add

    let spacer = NSView()
    spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    let footerRow = NSStackView(views: [cancelButton, spacer, add])
    footerRow.orientation = .horizontal
    footerRow.spacing = 8

    let headerRow = NSStackView(views: [backButton, titleField])
    headerRow.orientation = .horizontal
    headerRow.spacing = 8

    let stack = NSStackView(views: [headerRow, secret, issuer, account, error, footerRow])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    stack.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      secret.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
      issuer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
      account.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
      footerRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
    ])

    window?.contentView = container
    window?.setContentSize(NSSize(width: 440, height: 320))
  }

  @objc
  private func backToChooseMethod() {
    guard let item = pendingItem else { return }
    showChooseMethodStep(for: item)
  }

  @objc
  private func addSetupKeyTapped() {
    guard let item = pendingItem, let rawSecret = secretField?.stringValue else { return }
    let normalized =
      rawSecret.uppercased()
      .replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "-", with: "")
    guard let secretData = Base32.decode(normalized), let totp = try? TOTP(secret: secretData) else {
      showKeyError("That setup key doesn't look valid. Double-check it and try again.")
      return
    }

    let issuer = issuerField?.stringValue.trimmingCharacters(in: .whitespaces)
    let account = accountField?.stringValue.trimmingCharacters(in: .whitespaces)
    let uri = OTPAuthURI(
      issuer: (issuer?.isEmpty == false) ? issuer : nil,
      accountName: (account?.isEmpty == false) ? account! : item.title,
      totp: totp
    )
    save(item: item, totpURI: uri.url.absoluteString)
  }

  private func showKeyError(_ message: String) {
    keyErrorLabel?.stringValue = message
    keyErrorLabel?.isHidden = false
  }

  // MARK: - Step 3b/3c: QR image file / scan screen

  @objc
  private func chooseQRImageFile() {
    guard let item = pendingItem, let window else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.image]
    panel.message = "Choose an image containing this item's verification code QR code."

    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard let uri = Self.decodeOTPAuthURI(fromImageAt: url) else {
      presentAlert(
        message: "No Verification Code Found",
        informative: "That image doesn't seem to contain a verification code QR code.",
        in: window
      )
      return
    }
    save(item: item, totpURI: uri.url.absoluteString)
  }

  private static func decodeOTPAuthURI(fromImageAt url: URL) -> OTPAuthURI? {
    guard let nsImage = NSImage(contentsOf: url) else { return nil }
    var rect = NSRect(origin: .zero, size: nsImage.size)
    guard let cgImage = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
    return QRCodeReader.decodeOTPAuthURIs(from: cgImage).first
  }

  @objc
  private func chooseScanScreen() {
    guard let item = pendingItem, let window else { return }
    Task { [weak self] in
      guard let self else { return }
      do {
        let image = try await Self.captureScreen()
        guard let uri = QRCodeReader.decodeOTPAuthURIs(from: image).first else {
          throw CaptureError.noCodeFound
        }
        self.save(item: item, totpURI: uri.url.absoluteString)
      } catch {
        self.presentAlert(
          message: "No Verification Code Found",
          informative: Self.captureErrorMessage(error),
          in: window
        )
      }
    }
  }

  private static func captureErrorMessage(_ error: Swift.Error) -> String {
    switch error {
    case CaptureError.noCodeFound:
      return "No verification code QR code was found on screen. Make sure it's visible, then try again."
    case CaptureError.noDisplay:
      return "No display was available to capture."
    default:
      return "\(LilPasswordsKit.productName) couldn't capture the screen. Check that it has Screen Recording "
        + "permission in System Settings > Privacy & Security, then try again."
    }
  }

  /// Captures the whole main display as a single still image: `ScreenCaptureKit`'s one-shot
  /// screenshot API on macOS 14+, falling back to the older `CGWindowListCreateImage` on macOS 13
  /// (this app's deployment target) where that API doesn't exist yet.
  private static func captureScreen() async throws -> CGImage {
    if #available(macOS 14.0, *) {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
      guard let display = content.displays.first else { throw CaptureError.noDisplay }
      let filter = SCContentFilter(display: display, excludingWindows: [])
      let configuration = SCStreamConfiguration()
      configuration.width = display.width
      configuration.height = display.height
      return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    } else {
      guard
        let image = CGWindowListCreateImage(.infinite, .optionOnScreenOnly, kCGNullWindowID, .bestResolution)
      else {
        throw CaptureError.captureFailed
      }
      return image
    }
  }

  private func presentAlert(message: String, informative: String, in window: NSWindow) {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = informative
    alert.alertStyle = .warning
    alert.beginSheetModal(for: window)
  }

  // MARK: - Saving

  private func save(item: PasswordItem, totpURI: String) {
    var updated = item
    updated.totpURI = totpURI
    updated.modifiedAt = Date()
    dataSource.save(updated)
    finish(outcome: .saved(updated))
  }
}

extension AddVerificationCodeSheetController: NSTableViewDataSource, NSTableViewDelegate {
  func numberOfRows(in tableView: NSTableView) -> Int {
    filteredItems.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard filteredItems.indices.contains(row) else { return nil }
    let cell = ItemRowCellView.dequeue(from: tableView, owner: self)
    // This picker list doesn't use the item list's rounded, inset selection highlight (851-2463),
    // so there's no selection shape for a hairline to visually cut through — always show it.
    cell.configure(with: filteredItems[row], hidesSeparator: false)
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    continueButton?.isEnabled = itemsTableView?.selectedRow ?? -1 >= 0
  }
}

extension AddVerificationCodeSheetController: NSSearchFieldDelegate, NSTextFieldDelegate {
  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSTextField else { return }
    if field is NSSearchField {
      let query = field.stringValue.trimmingCharacters(in: .whitespaces)
      filteredItems =
        query.isEmpty
        ? allItems
        : allItems.filter { $0.searchScore(for: query) != nil }
      itemsTableView?.reloadData()
      continueButton?.isEnabled = false
    } else if field == secretField {
      keyErrorLabel?.isHidden = true
      addButton?.isEnabled = !(secretField?.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }
  }
}
