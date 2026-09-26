#if DEBUG
  import AppKit
  import LilPasswordsKit

  /// DEBUG-only entry points for tophatting the recovery kit and restore-vault sheets before
  /// onboarding (851-2439, not built yet) has a real "vault just got created" moment to call
  /// `RecoveryKitFlow` from, and before `LilPasswordsAgent`'s XPC surface (851-2427, not built yet)
  /// gives the app a real `VaultStoring` to call `restoreKey` on.
  ///
  /// Installs two local (in-app-only) keyboard shortcuts against a throwaway `InMemoryVaultStore`,
  /// rather than adding a menu item to `MainMenu.swift` — 851-2424 is actively editing that file for
  /// the real menu bar, and a debug shortcut here doesn't need to live there.
  ///
  /// - Cmd-Shift-R: creates a fresh demo vault (once) and shows the "save your recovery key" sheet.
  /// - Cmd-Shift-O: shows the "restore from recovery key" sheet against that same demo vault, so
  ///   pasting the key `RecoveryKitFlow` just showed exercises the success path, and typing
  ///   anything else exercises the friendly-error path.
  @MainActor
  enum RecoveryKitDebugMenu {
    private static var monitor: Any?
    private static let demoStore = InMemoryVaultStore()

    static func install(presentingWindow window: @escaping () -> NSWindow?) {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift],
          let window = window()
        else {
          return event
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r":
          presentRecoveryKitDemo(over: window)
          return nil
        case "o":
          presentRestoreDemo(over: window)
          return nil
        default:
          return event
        }
      }
    }

    private static func presentRecoveryKitDemo(over window: NSWindow) {
      Task {
        do {
          let recoveryKey = try await demoStore.createVault()
          RecoveryKitFlow.presentAfterVaultCreation(recoveryKey: recoveryKey, over: window) { saved in
            NSLog("[RecoveryKitDebugMenu] recovery kit sheet finished, saved=\(saved)")
          }
        } catch {
          // `createVault()` only ever hands back a recovery key once, per vault — a second
          // Cmd-Shift-R press hits this because the demo store already has one from the first.
          NSLog("[RecoveryKitDebugMenu] demo vault already exists, showing restore instead: \(error)")
          presentRestoreDemo(over: window)
        }
      }
    }

    private static func presentRestoreDemo(over window: NSWindow) {
      RecoveryKitFlow.presentRestore(store: demoStore, appName: LilPasswordsKit.productName, over: window) { outcome in
        NSLog("[RecoveryKitDebugMenu] restore sheet finished: \(outcome)")
      }
    }
  }

  /// Headless tophat capture, driven by the `LIL_PASSWORDS_TOPHAT_DIR` environment variable (see
  /// `AppDelegate`). Renders each recovery-kit screen as an actual sheet on a throwaway parent
  /// window, then shells out to `/usr/sbin/screencapture -l<windowNumber>` to grab pixels — so
  /// capture goes through the already-permitted system tool rather than needing this ad-hoc-signed
  /// debug build to hold its own Screen Recording grant — and exits. Uses `orderFrontRegardless()`
  /// only, never `NSApp.activate` or UI-automation keystrokes, so it can't steal focus or switch
  /// Spaces on a desktop other agents may be sharing.
  extension RecoveryKitDebugMenu {
    static func runTophatCapture(outputDirectory: URL) {
      try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

      let recoveryKey = VaultCrypto.RecoveryKey.generate()
      let pdfData = RecoveryKitDocument.renderPDF(
        RecoveryKitDocument.Content(appName: LilPasswordsKit.productName, displayKey: recoveryKey.displayString)
      )
      try? pdfData.write(to: outputDirectory.appendingPathComponent("recovery-kit.pdf"))
      if let png = RecoveryKitDocument.renderFirstPagePNG(from: pdfData) {
        try? png.write(to: outputDirectory.appendingPathComponent("recovery-kit-pdf-page1.png"))
      }

      captureAsSheet(
        RecoveryKitRevealViewController(
          appName: LilPasswordsKit.productName, recoveryKey: recoveryKey, pdfData: pdfData),
        filename: "recovery-kit-reveal-sheet.png",
        in: outputDirectory
      )

      captureAsSheet(
        RecoveryKitConfirmViewController(appName: LilPasswordsKit.productName, recoveryKey: recoveryKey),
        filename: "recovery-kit-confirm-sheet.png",
        in: outputDirectory
      )

      let restoreStore = InMemoryVaultStore()
      let parent = makeParentWindow()
      parent.orderFrontRegardless()
      RestoreVaultSheetController.present(store: restoreStore, appName: LilPasswordsKit.productName, from: parent) {
        _ in
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))
      if let sheetWindow = parent.sheets.first {
        captureWindow(sheetWindow, filename: "restore-vault-sheet.png", in: outputDirectory)
        parent.endSheet(sheetWindow)
      }
      parent.orderOut(nil)

      exit(0)
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
