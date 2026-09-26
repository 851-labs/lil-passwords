import AppKit
import Combine
import LilPasswordsKit

/// Hosts the main window: a three-column `NSSplitViewController` (sidebar, item list, detail)
/// under a unified toolbar, matching Apple Passwords. See App/Sources/MainWindow/ for the
/// pieces this assembles.
@MainActor
final class MainWindowController: NSWindowController {
  private let store = VaultSnapshotStore()
  private let dataSource: VaultViewModel
  private let splitViewController: MainSplitViewController
  private let toolbarController = MainToolbarController()

  private var itemsDidChangeCancellable: AnyCancellable?
  private var searchKeyMonitor: Any?

  init() {
    // `InMemoryVaultStore` is a real `VaultStoring` conformance (851-2404) — real crypto, real
    // CRUD/change-log semantics — just without a SQLite file or cross-process Darwin
    // notifications. It stands in for the XPC-backed `VaultStore` the app will talk to once
    // `LilPasswordsAgent` (851-2427) can hand one back; nothing above `VaultViewModel` changes
    // when that swap happens.
    let vaultStore = InMemoryVaultStore()
    let dataSource = VaultStoreViewModel(store: vaultStore)
    self.dataSource = dataSource
    splitViewController = MainSplitViewController(store: store, dataSource: dataSource)

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
    toolbarController.splitView = splitViewController.splitView
    window.toolbar = toolbarController.makeToolbar()

    store.update(VaultSnapshot(items: dataSource.items))
    itemsDidChangeCancellable = dataSource.itemsDidChange
      .receive(on: RunLoop.main)
      .sink { [weak self] in
        guard let self else { return }
        store.update(VaultSnapshot(items: dataSource.items))
      }

    // `start()` is async (it has to unlock the vault before any CRUD works), but `init()` isn't,
    // so it's kicked off here as an unstructured `Task` — `dataSource.items` stays empty until it
    // completes, same as any other async load, and `itemsDidChange` above picks up the result.
    Task { [dataSource] in
      var seedItems: [PasswordItem] = []
      #if DEBUG
        if SampleData.isEnabled {
          seedItems = SampleData.makeItems()
        }
      #endif
      await dataSource.start(seeding: seedItems)
    }

    // ⌘F focuses the search field (851-2417). Handled as a local event monitor, rather than a
    // `MainMenu.swift` menu item's action, since that file is 851-2424's. The search field itself
    // lives in the list column's header, not the toolbar (851-2461).
    searchKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self,
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
        event.charactersIgnoringModifiers?.lowercased() == "f"
      else {
        return event
      }
      splitViewController.listViewController.focusSearchField()
      return nil
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  isolated deinit {
    if let searchKeyMonitor {
      NSEvent.removeMonitor(searchKeyMonitor)
    }
  }
}
