import AppKit

/// Builds and manages the unified toolbar: sidebar toggle, a "+" add button, and a share button,
/// matching Apple Passwords' toolbar layout. The search field is *not* here — Apple Passwords puts
/// it at the top of the list column rather than the toolbar's centered/principal position, so it
/// lives in `ItemListViewController` instead (851-2461).
@MainActor
final class MainToolbarController: NSObject, NSToolbarDelegate {
  static let toolbarIdentifier = NSToolbar.Identifier("MainWindowToolbar")

  private enum ItemIdentifier {
    static let add = NSToolbarItem.Identifier("AddItem")
    static let share = NSToolbarItem.Identifier("ShareItem")
  }

  /// The split view whose first divider the sidebar-tracking separator should follow.
  weak var splitView: NSSplitView?

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
    menu.addItem(withTitle: "New Password…", action: nil, keyEquivalent: "")
    menu.addItem(withTitle: "New Passkey…", action: nil, keyEquivalent: "")
    menu.addItem(withTitle: "New Wi-Fi Password…", action: nil, keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "New Secure Note…", action: nil, keyEquivalent: "")
    menu.items.forEach { $0.isEnabled = false }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
  }
}
