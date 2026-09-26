import AppKit

/// Builds and manages the unified toolbar, matching Apple Passwords' per-column layout (851-2463):
///
/// - Over the list column: a two-line title (category name + "N Items", `ListTitleToolbarView`)
///   leading, and a capsule housing the sort menu and "+" trailing (`CapsuleToolbarView`).
/// - Over the detail column: an Edit/Cancel/Done control (`DetailEditToolbarView`) leading, and a
///   search field filling the rest of that column's toolbar width.
///
/// A tracking separator sits on each divider (sidebar/list, list/detail) so both title-bearing
/// regions above resize with their column. Query text/focus for the search field are still handled
/// by `ItemListViewController` (851-2417); edit state is still handled by `DetailViewController`
/// (851-2414) — this controller only builds and lays out the toolbar chrome, same as before this
/// ticket, just rearranged. The share button from before 851-2463 is gone entirely: there's no
/// destination for it yet, and Apple's own detail toolbar in the reference this ticket matches
/// against doesn't show one either.
@MainActor
final class MainToolbarController: NSObject, NSToolbarDelegate {
  static let toolbarIdentifier = NSToolbar.Identifier("MainWindowToolbar")

  private enum ItemIdentifier {
    static let listTitle = NSToolbarItem.Identifier("ListTitleItem")
    static let listActions = NSToolbarItem.Identifier("ListActionsItem")
    static let listDetailTrackingSeparator = NSToolbarItem.Identifier("ListDetailTrackingSeparator")
    static let edit = NSToolbarItem.Identifier("EditItem")
    static let search = NSToolbarItem.Identifier("SearchItem")
  }

  /// The split view whose dividers the tracking separators follow: divider 0 (sidebar/list) for
  /// `.sidebarTrackingSeparator`, divider 1 (list/detail) for `ItemIdentifier.listDetailTrackingSeparator`.
  weak var splitView: NSSplitView?

  /// Leading over the list column: the current category's name + item count. `ItemListViewController`
  /// pushes new text into this whenever its rows are rebuilt (rename from before this ticket, when
  /// this text lived in the list's own in-content header row rather than the toolbar).
  let listTitleView = ListTitleToolbarView()

  /// Trailing over the list column, grouped in one capsule: sort-options menu and "+". `sortButton`'s
  /// target/action is wired by `MainWindowController` once `ItemListViewController` exists (mirrors
  /// how `searchField.delegate` is wired below); `addButton` stays entirely self-contained here,
  /// exactly as the standalone "+" toolbar item was before this ticket (see `showAddMenu` below) —
  /// only its position moved, not its wiring, so 851-2416's sheet keeps opening from it unchanged.
  private let listActionsView: CapsuleToolbarView
  var sortButton: NSButton { listActionsView.buttons[0] }

  /// Leading over the detail column: Edit, or Cancel/Done while editing. Its closures are wired by
  /// `DetailViewController`, same pattern as `searchField`'s delegate below.
  let editControl = DetailEditToolbarView()

  /// Built once, up front, rather than fabricated fresh each time `toolbar(_:itemForItemIdentifier:...)`
  /// is called — `MainWindowController` needs a stable `NSSearchField` reference to hand to
  /// `ItemListViewController` before the toolbar is even attached to the window.
  private lazy var searchToolbarItem: NSSearchToolbarItem = {
    let item = NSSearchToolbarItem(itemIdentifier: ItemIdentifier.search)
    item.searchField.placeholderString = "Search"
    // The search field now spans the *detail* column (851-2463, reversing 851-2461's list-column
    // placement): only one tracking separator precedes it, so its width stretches from there to
    // the toolbar's trailing edge. This is a fallback minimum in case that stretch doesn't kick in
    // (e.g. an extreme resize), so it never collapses to unreadably narrow.
    item.preferredWidthForSearchField = 200
    return item
  }()

  /// The toolbar's search field, handed to `ItemListViewController` so it can focus it (⌘F) and
  /// receive its text-change/cancel delegate callbacks — `MainToolbarController` builds the field,
  /// but doesn't know anything about search query handling itself.
  var searchField: NSSearchField { searchToolbarItem.searchField }

  override init() {
    let sortButton = NSButton(
      image: NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort") ?? NSImage(),
      target: nil,
      action: nil
    )
    let addButton = NSButton(
      image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Item") ?? NSImage(),
      target: nil,
      action: nil
    )
    listActionsView = CapsuleToolbarView(buttons: [sortButton, addButton])
    super.init()
    addButton.target = self
    addButton.action = #selector(showAddMenu(_:))
  }

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
      ItemIdentifier.listTitle,
      .flexibleSpace,
      ItemIdentifier.listActions,
      ItemIdentifier.listDetailTrackingSeparator,
      ItemIdentifier.edit,
      ItemIdentifier.search,
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

    case ItemIdentifier.listTitle:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.view = listTitleView
      item.label = "Category"
      item.visibilityPriority = .high
      return item

    case ItemIdentifier.listActions:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.view = listActionsView
      item.label = "List Actions"
      return item

    case ItemIdentifier.listDetailTrackingSeparator:
      guard let splitView else { return nil }
      return NSTrackingSeparatorToolbarItem(identifier: itemIdentifier, splitView: splitView, dividerIndex: 1)

    case ItemIdentifier.edit:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.view = editControl
      item.label = "Edit"
      return item

    case ItemIdentifier.search:
      return searchToolbarItem

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
