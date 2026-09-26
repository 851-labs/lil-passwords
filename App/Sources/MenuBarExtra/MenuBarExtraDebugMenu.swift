#if DEBUG
  import AppKit
  import LilPasswordsKit

  /// Headless tophat capture for the menu bar extra (851-2425), driven by the same
  /// `LIL_PASSWORDS_TOPHAT_DIR` environment variable as `ImportExportDebugMenu`/
  /// `RecoveryKitDebugMenu` (see `AppDelegate`). Builds a real `NSPopover` against a throwaway
  /// anchor window and shells out to `/usr/sbin/screencapture -l<windowNumber>` for each of the
  /// requested shots — search/list, a typed query, an item's detail, and the locked state, each
  /// in both light and dark — using `orderFrontRegardless()` only, never `NSApp.activate` or
  /// UI-automation keystrokes, so it can't steal focus or switch Spaces on a desktop other agents
  /// may be sharing.
  ///
  /// Drives its own `LockCoordinator` against `OfflineDemoAgent` + `AlwaysSucceedAuthenticator`
  /// (the same pair `MainWindowController` uses under `LILPASSWORDS_OFFLINE_DEMO=1`/
  /// `LILPASSWORDS_FAKE_AUTH=1`) rather than the real helper connection, so this capture pass
  /// can't race another concurrently-running worktree's manual testing over the one shared Mach
  /// service/vault database — see `OfflineDemoAgent`'s documentation.
  @MainActor
  enum MenuBarExtraDebugMenu {
    static func runTophatCapture(outputDirectory: URL) {
      try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

      let sampleItems = SampleData.makeItems()
      let vaultViewModel = VaultStoreViewModel(store: InMemoryVaultStore())
      Task { await vaultViewModel.start(seeding: sampleItems) }
      RunLoop.current.run(until: Date().addingTimeInterval(0.3))

      let lockCoordinator = LockCoordinator(agent: OfflineDemoAgent(), authenticator: AlwaysSucceedAuthenticator())
      let root = MenuBarRootViewController(vaultViewModel: vaultViewModel, lockCoordinator: lockCoordinator) {}

      let popover = NSPopover()
      popover.behavior = .applicationDefined
      popover.contentViewController = root
      popover.contentSize = MenuBarRootViewController.popoverSize

      let anchorWindow = makeAnchorWindow()
      anchorWindow.orderFrontRegardless()
      // `viewDidLoad()` (and its `LockCoordinator.state` read) only fires once `root.view` is
      // materialized — force that now, before the locked-state captures below, rather than
      // waiting for `NSPopover` to do it lazily on first `show(relativeTo:)`.
      _ = root.view

      // `OfflineDemoAgent` starts `locked == true`, so the coordinator's very next state (whether
      // read as `.checking` before a `refresh()` or `.locked` after one — `MenuBarLockedViewController`
      // renders both identically) already matches what this block wants to capture.
      capturePopover(
        popover, anchor: anchorWindow.contentView!, filename: "menu-bar-locked-light.png", in: outputDirectory,
        darkMode: false)
      capturePopover(
        popover, anchor: anchorWindow.contentView!, filename: "menu-bar-locked-dark.png", in: outputDirectory,
        darkMode: true)

      Task { await lockCoordinator.unlock() }
      RunLoop.current.run(until: Date().addingTimeInterval(0.3))

      capturePopover(
        popover, anchor: anchorWindow.contentView!, filename: "menu-bar-list-light.png", in: outputDirectory,
        darkMode: false, prepare: { root.popoverWillShow() })
      capturePopover(
        popover, anchor: anchorWindow.contentView!, filename: "menu-bar-list-dark.png", in: outputDirectory,
        darkMode: true, prepare: { root.popoverWillShow() })

      capturePopover(
        popover, anchor: anchorWindow.contentView!, filename: "menu-bar-search-light.png", in: outputDirectory,
        darkMode: false,
        prepare: {
          root.popoverWillShow()
          root.debugSetSearchQuery("net")
        }
      )

      let detailItem = sampleItems.first { $0.title == "GitHub" } ?? sampleItems[0]
      capturePopover(
        popover, anchor: anchorWindow.contentView!, filename: "menu-bar-detail-light.png", in: outputDirectory,
        darkMode: false,
        prepare: {
          root.popoverWillShow()
          root.debugSelectItem(detailItem)
        }
      )
      capturePopover(
        popover, anchor: anchorWindow.contentView!, filename: "menu-bar-detail-dark.png", in: outputDirectory,
        darkMode: true,
        prepare: {
          root.popoverWillShow()
          root.debugSelectItem(detailItem)
        }
      )

      anchorWindow.orderOut(nil)
    }

    private static func makeAnchorWindow() -> NSWindow {
      let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 28, height: 22),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
      )
      window.isReleasedWhenClosed = false
      window.level = .statusBar
      window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 28, height: 22))
      return window
    }

    private static func capturePopover(
      _ popover: NSPopover,
      anchor: NSView,
      filename: String,
      in directory: URL,
      darkMode: Bool,
      prepare: (() -> Void)? = nil
    ) {
      prepare?()
      popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
      RunLoop.current.run(until: Date().addingTimeInterval(0.3))

      guard let window = popover.contentViewController?.view.window else {
        popover.performClose(nil)
        return
      }
      // Setting `.appearance` on just the window isn't enough to make an `NSPopover`'s own content
      // actually redraw dark — its content view controller's view needs the override too (the
      // window's `appearance` only changes what *new* views would inherit by default, not
      // necessarily what's already on screen for a popover's internally-managed window), so set
      // both explicitly.
      let appearance = darkMode ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
      window.appearance = appearance
      popover.contentViewController?.view.appearance = appearance
      RunLoop.current.run(until: Date().addingTimeInterval(0.3))

      let outputURL = directory.appendingPathComponent(filename)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-o", "-l\(window.windowNumber)", outputURL.path]
      try? process.run()
      process.waitUntilExit()

      popover.performClose(nil)
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
  }
#endif
