import AppKit
import LilPasswordsKit

/// Orchestrates the whole "File → Import Passwords…" flow as a single sheet, swapping
/// `window.contentViewController` between steps the same way `RecoveryKitSheetController` does:
///
/// 1. Parse the CSV the user picked (``ImportHelpViewController`` if that fails, or the format
///    isn't recognized, or the file has nothing importable — with a "choose a different file" way
///    back to step 0).
/// 2. Plan it against the current vault contents (``ImportMergePlanner``) and show the result in
///    ``ImportPreviewViewController`` for the user to review/resolve conflicts.
/// 3. Apply the resulting decisions through `VaultViewModel.save(_:)` and show
///    ``ImportCompletionViewController``.
@MainActor
final class ImportSheetController: NSWindowController {
  private let csvURL: URL
  private let dataSource: VaultViewModel
  private weak var parentWindow: NSWindow?
  private var completion: (() -> Void)?

  private init(csvURL: URL, dataSource: VaultViewModel, parentWindow: NSWindow) {
    self.csvURL = csvURL
    self.dataSource = dataSource
    self.parentWindow = parentWindow

    let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Import Passwords"
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Presents the import sheet over `parentWindow`, parsing `csvURL` immediately. `completion` is
  /// called once the sheet is dismissed, however that happens (cancel, or finishing the import).
  static func present(
    csvURL: URL,
    dataSource: VaultViewModel,
    from parentWindow: NSWindow,
    completion: @escaping () -> Void
  ) {
    let controller = ImportSheetController(csvURL: csvURL, dataSource: dataSource, parentWindow: parentWindow)
    controller.completion = completion
    guard let sheetWindow = controller.window else {
      completion()
      return
    }
    controller.showParsedStep()
    parentWindow.beginSheet(sheetWindow) { _ in
      withExtendedLifetime(controller) {}
    }
  }

  private func showParsedStep() {
    switch Self.parse(csvURL: csvURL) {
    case .success(let credentials):
      showPreview(credentials: credentials)
    case .failure(let failure):
      showHelp(message: failure.message)
    }
  }

  /// A user-facing reason a CSV file couldn't be imported, shown as the message on
  /// ``ImportHelpViewController``.
  struct ParseFailure: Error {
    let message: String
  }

  /// Reads and parses `url`, returning either the credentials it contains or a user-facing reason
  /// it couldn't be imported. Shared by the real flow above and the DEBUG tophat capture, so both
  /// exercise the exact same parsing path.
  static func parse(csvURL url: URL) -> Result<[ImportedCredential], ParseFailure> {
    let text: String
    do {
      text = try String(contentsOf: url, encoding: .utf8)
    } catch {
      return .failure(ParseFailure(message: "That file couldn't be opened: \(error.localizedDescription)"))
    }

    guard (try? CSVImporter.detectFormat(text)) != nil else {
      return .failure(ParseFailure(message: "That file's format wasn't recognized as one this app can import."))
    }

    do {
      let result = try CSVImporter.importCSV(text)
      guard !result.credentials.isEmpty else {
        return .failure(ParseFailure(message: "That file didn't contain any passwords to import."))
      }
      return .success(result.credentials)
    } catch {
      return .failure(ParseFailure(message: "That file couldn't be read as a CSV: \(error.localizedDescription)"))
    }
  }

  /// Builds an ``ImportPlan`` for `credentials` against the vault's current, non-deleted items.
  static func plan(for credentials: [ImportedCredential], against dataSource: VaultViewModel) -> ImportPlan {
    let existing = dataSource.items.filter { $0.deletedAt == nil }.map { $0.asExistingCredential() }
    return ImportMergePlanner.plan(importing: credentials, against: existing)
  }

  private func showPreview(credentials: [ImportedCredential]) {
    let plan = Self.plan(for: credentials, against: dataSource)
    let preview = ImportPreviewViewController(plan: plan)
    preview.onCancel = { [weak self] in self?.finish() }
    preview.onImport = { [weak self] rows in self?.apply(rows) }
    window?.contentViewController = preview
  }

  private func showHelp(message: String) {
    let help = ImportHelpViewController(message: message)
    help.onCancel = { [weak self] in self?.finish() }
    help.onChooseDifferentFile = { [weak self] in self?.chooseDifferentFile() }
    window?.contentViewController = help
  }

  private func chooseDifferentFile() {
    finish()
    guard let parentWindow else { return }
    ImportFlow.presentOpenPanel(dataSource: dataSource, from: parentWindow, completion: completion ?? {})
  }

  /// Applies each row's decision to the vault, per its resolution:
  /// - `.new` → always added.
  /// - `.duplicate` → always skipped (identical to what's already there; nothing to add).
  /// - `.conflict` with `.keepExisting` → skipped, existing item untouched.
  /// - `.conflict` with `.replace` → the existing item's fields are overwritten in place.
  /// - `.conflict` with `.keepBoth` → the imported row is added as a brand-new, separate item.
  private func apply(_ rows: [ImportPreviewRow]) {
    var importedCount = 0
    for row in rows {
      switch row.decision {
      case .new(let imported):
        dataSource.save(imported.asPasswordItem())
        importedCount += 1

      case .duplicate:
        continue

      case .conflict(let imported, let existing):
        switch row.resolution {
        case .keepExisting:
          continue
        case .replace:
          if let existingItem = dataSource.items.first(where: { $0.id.uuidString == existing.id }) {
            dataSource.save(imported.replacing(existingItem))
          } else {
            dataSource.save(imported.asPasswordItem())
          }
          importedCount += 1
        case .keepBoth:
          dataSource.save(imported.asPasswordItem())
          importedCount += 1
        }
      }
    }

    let completionViewController = ImportCompletionViewController(importedCount: importedCount, csvURL: csvURL)
    completionViewController.onDone = { [weak self] in self?.finish() }
    window?.contentViewController = completionViewController
  }

  private func finish() {
    guard let window else { return }
    if let sheetParent = window.sheetParent {
      sheetParent.endSheet(window)
    } else {
      window.close()
    }
    completion?()
  }
}
