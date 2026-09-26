import AppKit
import LilPasswordsKit

/// Hosts the main window: a three-column `NSSplitViewController` (sidebar, item list, detail)
/// under a unified toolbar, matching Apple Passwords. See App/Sources/MainWindow/ for the
/// pieces this assembles.
@MainActor
final class MainWindowController: NSWindowController {
  private let store = VaultSnapshotStore()
  private let splitViewController: MainSplitViewController
  private let toolbarController = MainToolbarController()

  init(vaultViewModel: VaultViewModel) {
    splitViewController = MainSplitViewController(store: store, vaultViewModel: vaultViewModel)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = LilPasswordsKit.productName
    // Apple Passwords shows no title text in the titlebar, just the toolbar controls.
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified
    window.identifier = NSUserInterfaceItemIdentifier("MainWindow")
    window.isRestorable = true
    window.setFrameAutosaveName("MainWindow")
    window.minSize = NSSize(width: 620, height: 400)
    window.center()

    super.init(window: window)

    window.contentViewController = splitViewController
    toolbarController.delegate = self
    toolbarController.splitView = splitViewController.splitView
    window.toolbar = toolbarController.makeToolbar()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }
}

extension MainWindowController: MainToolbarControllerDelegate {
  func toolbarController(_ controller: MainToolbarController, searchTextDidChange text: String) {
    // Filtering the item list depends on the real item model (851-2403); nothing to filter yet.
  }
}
