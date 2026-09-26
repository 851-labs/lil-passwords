import AppKit

/// Builds and manages the unified toolbar: sidebar toggle, a search field spanning the list
/// column, a "+" add button, and a share button, matching Apple Passwords' toolbar layout. The
/// search field sits *in the toolbar row itself* — not the toolbar's old centered/principal
/// position, and not below the toolbar either — flanked by a tracking separator on each side
/// (the sidebar/list divider and the list/detail divider) so its width tracks the list column
/// (851-2461). Query text and focus are still handled by `ItemListViewController`, which is handed
/// this field's `NSSearchField` instance (see `searchField` below) rather than owning one itself.
@MainActor
final class MainToolbarController: NSObject, NSToolbarDelegate {
  static let toolbarIdentifier = NSToolbar.Identifier("MainWindowToolbar")

  private enum ItemIdentifier {
    static let search = NSToolbarItem.Identifier("SearchItem")
    static let listDetailTrackingSeparator = NSToolbarItem.Identifier("ListDetailTrackingSeparator")
    static let add = NSToolbarItem.Identifier("AddItem")
    static let share = NSToolbarItem.Identifier("ShareItem")
  }

  /// The split view whose dividers the tracking separators follow: divider 0 (sidebar/list) for
  /// `.sidebarTrackingSeparator`, divider 1 (list/detail) for `ItemIdentifier.listDetailTrackingSeparator`.
  weak var splitView: NSSplitView?

  /// Built once, up front, rather than fabricated fresh each time `toolbar(_:itemForItemIdentifier:...)`
  /// is called — `MainWindowController` needs a stable `NSSearchField` reference to hand to
  /// `ItemListViewController` before the toolbar is even attached to the window.
  private lazy var searchToolbarItem: NSSearchToolbarItem = {
    let item = NSSearchToolbarItem(itemIdentifier: ItemIdentifier.search)
    item.searchField.placeholderString = "Search"
    // Between the two tracking separators below, the search field's width normally stretches to
    // fill the list column automatically. This is a fallback minimum in case that tracking doesn't
    // kick in (e.g. an extreme resize), so it never collapses to unreadably narrow.
    item.preferredWidthForSearchField = 260
    return item
  }()

  /// The toolbar's search field, handed to `ItemListViewController` so it can focus it (⌘F) and
  /// receive its text-change/cancel delegate callbacks — `MainToolbarController` builds the field,
  /// but doesn't know anything about search query handling itself.
  var searchField: NSSearchField { searchToolbarItem.searchField }

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
      ItemIdentifier.search,
      ItemIdentifier.listDetailTrackingSeparator,
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
      return searchToolbarItem

    case ItemIdentifier.listDetailTrackingSeparator:
      guard let splitView else { return nil }
      return NSTrackingSeparatorToolbarItem(identifier: itemIdentifier, splitView: splitView, dividerIndex: 1)

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
