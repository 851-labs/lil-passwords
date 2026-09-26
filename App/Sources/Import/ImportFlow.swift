import AppKit
import LilPasswordsKit
import UniformTypeIdentifiers

/// The entry point for "File → Import Passwords…": opens an `NSOpenPanel` for a `.csv` file, then
/// hands off to ``ImportSheetController`` to parse it and walk the user through the rest. Kept
/// separate from ``ImportSheetController`` so "choose a different file" (reached from the sheet's
/// help step) can re-open the panel without the sheet controller needing to know about `NSOpenPanel`
/// itself.
@MainActor
enum ImportFlow {
  static func presentOpenPanel(
    dataSource: VaultViewModel, from parentWindow: NSWindow, completion: @escaping () -> Void
  ) {
    let panel = NSOpenPanel()
    panel.title = String(localized: "Import Passwords")
    panel.prompt = String(localized: "Import")
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true

    panel.beginSheetModal(for: parentWindow) { response in
      guard response == .OK, let url = panel.url else {
        completion()
        return
      }
      ImportSheetController.present(csvURL: url, dataSource: dataSource, from: parentWindow, completion: completion)
    }
  }
}
