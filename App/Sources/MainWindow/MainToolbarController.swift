import AppKit

/// Told about toolbar actions the main window doesn't yet do anything real with (search
/// filtering and creating new items both depend on `PasswordItem`, 851-2403). Kept as a
/// protocol so the toolbar doesn't need to know what eventually implements this.
@MainActor
protocol MainToolbarControllerDelegate: AnyObject {
  func toolbarController(_ controller: MainToolbarController, searchTextDidChange text: String)
}

/// Builds and manages the unified toolbar: sidebar toggle, search field, a "+" add button, and
/// a share button, matching Apple Passwords' toolbar layout.
@MainActor
final class MainToolbarController: NSObject, NSToolbarDelegate {
  static let toolbarIdentifier = NSToolbar.Identifier("MainWindowToolbar")

  private enum ItemIdentifier {
    static let search = NSToolbarItem.Identifier("SearchItem")
    static let add = NSToolbarItem.Identifier("AddItem")
    static let share = NSToolbarItem.Identifier("ShareItem")
  }

  weak var delegate: MainToolbarControllerDelegate?

  /// The split view whose first divider the sidebar-tracking separator should follow.
  weak var splitView: NSSplitView?

  private var searchToolbarItem: NSSearchToolbarItem?

  func makeToolbar() -> NSToolbar {
    let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    toolbar.autosavesConfiguration = false
    return toolbar
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [
      .toggleSidebar,
      .sidebarTrackingSeparator,
      .flexibleSpace,
      ItemIdentifier.search,
      .flexibleSpace,
      ItemIdentifier.add,
      ItemIdentifier.share,
    ]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    switch itemIdentifier {
    case .toggleSidebar:
      return NSToolbarItem(itemIdentifier: itemIdentifier)

    case .sidebarTrackingSeparator:
      guard let splitView else { return nil }
      return NSTrackingSeparatorToolbarItem(identifier: itemIdentifier, splitView: splitView, dividerIndex: 0)

    case ItemIdentifier.search:
      let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
      item.searchField.placeholderString = "Search"
      item.searchField.delegate = self
      searchToolbarItem = item
      return item

    case ItemIdentifier.add:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      let button = NSButton(
        image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Item") ?? NSImage(),
        target: self,
        action: #selector(showAddMenu(_:))
      )
      item.view = button
      item.label = "New Item"
      return item

    case ItemIdentifier.share:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      let button = NSButton(
        image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share") ?? NSImage(),
        target: nil,
        action: nil
      )
      // Disabled until something is selected; there's nothing to select yet.
      button.isEnabled = false
      item.view = button
      item.label = "Share"
      return item

    default:
      return nil
    }
  }

  @objc
  private func showAddMenu(_ sender: NSButton) {
    let menu = NSMenu()
    // `nil`-targeted, same as `MainMenu.swift`'s File → New Password: resolved dynamically via
    // the responder chain, currently `MainSplitViewController.newPassword(_:)` (851-2416).
    menu.addItem(
      withTitle: "New Password…", action: #selector(MainSplitViewController.newPassword(_:)), keyEquivalent: "")
    menu.addItem(withTitle: "New Passkey…", action: nil, keyEquivalent: "")
    menu.addItem(withTitle: "New Wi-Fi Password…", action: nil, keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "New Secure Note…", action: nil, keyEquivalent: "")
    // The rest still have no real destination; only "New Password…" above should be enabled.
    for item in menu.items where item.action == nil {
      item.isEnabled = false
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
  }
}

extension MainToolbarController: NSSearchFieldDelegate {
  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSSearchField else { return }
    delegate?.toolbarController(self, searchTextDidChange: field.stringValue)
  }
}
