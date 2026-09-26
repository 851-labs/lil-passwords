#if DEBUG
  import AppKit
  import LilPasswordsKit

  /// Headless tophat capture for the New Password sheet's card layout (851-2416): renders the real
  /// sheet as an actual sheet over a throwaway parent window, then shells out to
  /// `/usr/sbin/screencapture -l<windowNumber>` to grab pixels — the same technique
  /// `RecoveryKitDebugMenu`/`ImportExportDebugMenu` use (a real sheet, `orderFrontRegardless()`
  /// only, never `NSApp.activate` or UI-automation keystrokes/AX), so this can't steal focus or
  /// interfere with any other worktree's copy of the app running on the same Mac. Keeps its own
  /// copies of the small window/capture helpers, since those files' are `private` to them.
  ///
  /// Captures once in light and once in dark appearance — 851-2416's spec compares this sheet
  /// against Apple Passwords' own New Password sheet in both — by overriding `NSApp.appearance`
  /// for the duration of each capture and restoring whatever it was before.
  @MainActor
  enum NewPasswordDebugMenu {
    static func runTophatCapture(outputDirectory: URL) {
      try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

      let savedAppearance = NSApp.appearance
      defer { NSApp.appearance = savedAppearance }

      capture(appearance: NSAppearance(named: .aqua), filename: "new-password-sheet-light.png", in: outputDirectory)
      capture(
        appearance: NSAppearance(named: .darkAqua), filename: "new-password-sheet-dark.png", in: outputDirectory)
    }

    private static func capture(appearance: NSAppearance?, filename: String, in directory: URL) {
      NSApp.appearance = appearance

      let parent = makeParentWindow()
      parent.orderFrontRegardless()

      // A throwaway, never-`start()`-ed view model: this sheet only needs *a* `VaultViewModel` to
      // satisfy `present(vaultViewModel:from:completion:)`'s signature — nothing in the capture
      // saves through it, so there's no vault to actually create first.
      let vaultViewModel = VaultStoreViewModel(store: InMemoryVaultStore())
      NewPasswordSheetController.present(vaultViewModel: vaultViewModel, from: parent) { _ in }
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))

      guard let sheetWindow = parent.sheets.first else {
        parent.orderOut(nil)
        return
      }
      captureWindow(sheetWindow, filename: filename, in: directory)
      parent.endSheet(sheetWindow)
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
