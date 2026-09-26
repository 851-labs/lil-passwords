#if DEBUG
  import AppKit
  import LilPasswordsKit

  /// DEBUG-only, headless tophat capture for the import/export flows (851-2410): parses a small
  /// inline fixture CSV engineered to produce one new row, one duplicate, and one conflicting row
  /// against a couple of hand-built ``ExistingCredential`` values, then screenshots each visible
  /// step. Deliberately builds the plan directly from ``ImportMergePlanner`` rather than going
  /// through a real ``VaultViewModel``/`InMemoryVaultStore` — nothing here needs a real vault, just
  /// the same view controllers the real flow shows, so there's no async vault setup to wait on
  /// before capturing.
  ///
  /// Mirrors `RecoveryKitDebugMenu`'s capture technique (same headless
  /// `/usr/sbin/screencapture -l<windowNumber>` pixel grab, `orderFrontRegardless()`/`orderOut(nil)`
  /// only, never `NSApp.activate` or keystroke automation) but keeps its own copies of the small
  /// window/sheet helpers, since that file's are `private` to it.
  @MainActor
  enum ImportExportDebugMenu {
    private static let fixtureCSV = """
      Title,URL,Username,Password,Notes,OTPAuth\r
      Figma,https://www.figma.com,jordan@example.com,Vector-Canvas-71,,\r
      Netflix,https://www.netflix.com,jordan@example.com,Str3am-Binge-77,,\r
      Slack,https://slack.com,jordan@example.com,NewPassword2,,\r
      """

    private static let existingCredentials = [
      ExistingCredential(
        id: "netflix",
        title: "Netflix",
        username: "jordan@example.com",
        password: "Str3am-Binge-77",
        urls: ["https://www.netflix.com"]
      ),
      ExistingCredential(
        id: "slack",
        title: "Slack",
        username: "jordan@example.com",
        password: "OldPassword1",
        urls: ["https://slack.com"]
      ),
    ]

    static func runTophatCapture(outputDirectory: URL) {
      try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

      let fixtureURL = outputDirectory.appendingPathComponent("import-fixture.csv")
      try? fixtureCSV.write(to: fixtureURL, atomically: true, encoding: .utf8)

      guard let credentials = try? CSVImporter.importCSV(fixtureCSV).credentials else { return }
      let plan = ImportMergePlanner.plan(importing: credentials, against: existingCredentials)

      captureAsSheet(ImportPreviewViewController(plan: plan), filename: "import-preview-sheet.png", in: outputDirectory)

      let help = ImportHelpViewController(
        message: "That file's format wasn't recognized as one this app can import."
      )
      captureAsSheet(help, filename: "import-help-sheet.png", in: outputDirectory)

      captureAsSheet(
        ImportCompletionViewController(importedCount: 2, csvURL: fixtureURL),
        filename: "import-completion-sheet.png",
        in: outputDirectory
      )

      let parent = makeParentWindow()
      parent.orderFrontRegardless()
      let alert = ExportFlow.makePlaintextWarningAlert()
      // `NSAlert.beginSheetModal(for:)` — not manually attaching `alert.window` as a sheet — is
      // what actually sizes/lays out the alert panel for its text; skipping it left a
      // default-sized, unlaid-out panel the one time this was tried directly.
      alert.beginSheetModal(for: parent) { _ in }
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))
      captureWindow(alert.window, filename: "export-plaintext-warning.png", in: outputDirectory)
      parent.endSheet(alert.window)
      parent.orderOut(nil)
    }

    private static func makeParentWindow() -> NSWindow {
      let parent = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 900, height: 700),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
      )
      parent.title = LilPasswordsKit.productName
      return parent
    }

    private static func captureAsSheet(_ contentViewController: NSViewController, filename: String, in directory: URL) {
      let parent = makeParentWindow()
      parent.orderFrontRegardless()

      let sheetWindow = NSWindow(contentViewController: contentViewController)
      parent.beginSheet(sheetWindow) { _ in }
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))

      captureWindow(sheetWindow, filename: filename, in: directory)

      parent.endSheet(sheetWindow)
      parent.orderOut(nil)
    }

    private static func captureWindow(_ window: NSWindow, filename: String, in directory: URL) {
      window.orderFrontRegardless()
      RunLoop.current.run(until: Date().addingTimeInterval(0.3))

      let outputURL = directory.appendingPathComponent(filename)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-o", "-l\(window.windowNumber)", outputURL.path]
      try? process.run()
      process.waitUntilExit()

      window.orderOut(nil)
    }
  }
#endif
