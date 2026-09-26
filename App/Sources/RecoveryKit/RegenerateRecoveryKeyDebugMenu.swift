#if DEBUG
  import AppKit
  import LilPasswordsKit

  /// DEBUG-only, headless tophat capture for the "Generate New Recovery Key…" flow (851-2462):
  /// the confirmation alert, the resulting kit sheet, and the rendered PDF page itself (the
  /// regression case for the blurry-QR fix).
  ///
  /// A separate file from `RecoveryKitDebugMenu`, with its own private copies of the small
  /// window/sheet helpers, for the same reason `ImportExportDebugMenu` keeps its own: those
  /// helpers are `private` to their own file.
  ///
  /// Doesn't drive `RegenerateRecoveryKeyFlow.present` end-to-end — that would need a real
  /// `LAContext` prompt (Touch ID/password), which nothing in this sandboxed, headless capture can
  /// press, and which would surface as a *different* process's window (SecurityAgent/CoreAuthUI),
  /// not this app's own. Instead, exactly like `ImportExportDebugMenu` captures `ExportFlow`'s
  /// plaintext warning by calling its `makePlaintextWarningAlert()` factory directly, this captures
  /// `RegenerateRecoveryKeyFlow.makeConfirmationAlert()` directly, and captures "the kit sheet" by
  /// calling `RecoveryKitFlow.presentAfterVaultCreation` with a freshly generated demo recovery
  /// key — the same technique `RecoveryKitDebugMenu` already uses for its own reveal-sheet capture,
  /// since rotating a real vault's recovery key isn't needed to show the same sheet.
  @MainActor
  enum RegenerateRecoveryKeyDebugMenu {
    static func runTophatCapture(outputDirectory: URL) {
      try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

      // The rendered PDF page itself — this is the direct regression artifact for the blurry-QR
      // fix (`RecoveryKitDocumentTests.qrCodeInRenderedPDFDecodesBackToTheDisplayKey`); no window
      // is needed to produce it.
      let recoveryKey = VaultCrypto.RecoveryKey.generate()
      let pdfData = RecoveryKitDocument.renderPDF(
        RecoveryKitDocument.Content(appName: LilPasswordsKit.productName, displayKey: recoveryKey.displayString)
      )
      if let png = RecoveryKitDocument.renderFirstPagePNG(from: pdfData, width: 1200) {
        try? png.write(to: outputDirectory.appendingPathComponent("regenerate-recovery-key-pdf-page1.png"))
      }

      let parent = makeParentWindow()
      parent.orderFrontRegardless()
      let confirmAlert = RegenerateRecoveryKeyFlow.makeConfirmationAlert()
      // `NSAlert.beginSheetModal(for:)` — not manually attaching `alert.window` as a sheet — is
      // what actually sizes/lays out the alert panel for its text (see `ImportExportDebugMenu`'s
      // identical note).
      confirmAlert.beginSheetModal(for: parent) { _ in }
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))
      captureWindow(confirmAlert.window, filename: "regenerate-recovery-key-confirm-alert.png", in: outputDirectory)
      parent.endSheet(confirmAlert.window)
      parent.orderOut(nil)

      let kitParent = makeParentWindow()
      kitParent.orderFrontRegardless()
      RecoveryKitFlow.presentAfterVaultCreation(recoveryKey: recoveryKey, over: kitParent) { _ in }
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))
      if let sheetWindow = kitParent.sheets.first {
        captureWindow(sheetWindow, filename: "regenerate-recovery-key-kit-sheet.png", in: outputDirectory)
        kitParent.endSheet(sheetWindow)
      }
      kitParent.orderOut(nil)
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
