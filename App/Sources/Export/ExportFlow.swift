import AppKit
import LilPasswordsKit
import UniformTypeIdentifiers

/// The entry point for "File → Export All Passwords…": authenticate, warn that the resulting file
/// is plaintext, let the user pick where to save it, then write it with ``CSVExporter``.
///
/// Authentication happens *before* the save panel (rather than after) so a user who isn't the
/// device owner can't even see the save panel appear — nothing about export should be visible
/// without proving device ownership first, not just gated at the last step.
@MainActor
enum ExportFlow {
  /// The plaintext warning shown after authentication succeeds, before the save panel. A static
  /// factory (rather than presenting it inline) so the DEBUG tophat capture can grab a screenshot
  /// of exactly this alert without driving a real `LAContext` prompt or writing a real file.
  static func makePlaintextWarningAlert() -> NSAlert {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "This File Will Contain Your Passwords in Plain Text"
    alert.informativeText =
      "Anyone with access to the exported file can read every password and two-factor code in it, "
      + "unprotected. Store it somewhere safe, and delete it as soon as you're done with it."
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")
    return alert
  }

  /// Starts the export flow, presenting sheets over `parentWindow` for each step.
  static func presentExport(
    dataSource: VaultViewModel,
    from parentWindow: NSWindow,
    deviceAuthenticator: DeviceAuthenticating = LAContextDeviceAuthenticator()
  ) {
    Task {
      do {
        try await deviceAuthenticator.authenticate(
          reason: "authenticate to export all your passwords as a plaintext file"
        )
      } catch {
        presentFailureAlert(
          message: "Authentication failed, so nothing was exported.",
          over: parentWindow
        )
        return
      }

      let warning = makePlaintextWarningAlert()
      warning.beginSheetModal(for: parentWindow) { response in
        guard response == .alertFirstButtonReturn else { return }
        presentSavePanel(dataSource: dataSource, from: parentWindow)
      }
    }
  }

  private static func presentSavePanel(dataSource: VaultViewModel, from parentWindow: NSWindow) {
    let panel = NSSavePanel()
    panel.title = "Export All Passwords"
    panel.prompt = "Export"
    panel.nameFieldStringValue = "\(LilPasswordsKit.productName) Export.csv"
    panel.allowedContentTypes = [.commaSeparatedText]

    panel.beginSheetModal(for: parentWindow) { response in
      guard response == .OK, let url = panel.url else { return }

      do {
        try CSVExporter.write(dataSource.items, to: url)
        presentSuccessAlert(count: dataSource.items.filter { $0.deletedAt == nil }.count, over: parentWindow)
      } catch {
        presentFailureAlert(
          message: "The file couldn't be written: \(error.localizedDescription)",
          over: parentWindow
        )
      }
    }
  }

  private static func presentSuccessAlert(count: Int, over window: NSWindow) {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Exported \(count) Password\(count == 1 ? "" : "s")"
    alert.informativeText = "Remember to delete the exported file once you're done with it — it's plain text."
    alert.beginSheetModal(for: window)
  }

  private static func presentFailureAlert(message: String, over window: NSWindow) {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Couldn't Export Passwords"
    alert.informativeText = message
    alert.beginSheetModal(for: window)
  }
}
