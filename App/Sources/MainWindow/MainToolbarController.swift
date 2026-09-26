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

  /// The toolbar built by `makeToolbar()` — kept (weakly; `window.toolbar` owns it) so
  /// `setFullWidthModeActive(_:)` can add/remove items after the fact, once the window already
  /// has a toolbar installed.
  private weak var toolbar: NSToolbar?

  /// Whether a full-width category view (Codes/Security/Deleted, 851-2418/851-2419/851-2420) is
  /// currently showing in place of the list+detail split. Those views replace
  /// `MainSplitViewController.detailViewController`'s content but not the window's toolbar, which
  /// is independent of split-view content — so left alone, this toolbar's list-column title/sort/
  /// add and detail-column Edit/search would keep floating uselessly (and confusingly, duplicating
  /// each full-width view's own "N Items" header) over content none of them apply to. Toggled by
  /// `MainSplitViewController.onFullWidthModeChange`, wired in `MainWindowController.init()`.
  private var isFullWidthModeActive = false

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
    // The image's own `accessibilityDescription` isn't reliably surfaced by VoiceOver as the
    // button's label on its own (851-2426) — every icon-only control gets its label set directly.
    sortButton.setAccessibilityLabel("Sort")
    addButton.setAccessibilityLabel("New Item")
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
    self.toolbar = toolbar
    return toolbar
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    isFullWidthModeActive ? fullWidthItemIdentifiers : splitViewItemIdentifiers
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    splitViewItemIdentifiers
  }

  /// The full list+detail layout's toolbar items (851-2463) — the default, and what's restored
  /// whenever `setFullWidthModeActive(false)` is called.
  private var splitViewItemIdentifiers: [NSToolbarItem.Identifier] {
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

  /// The reduced toolbar shown while a full-width category view (Codes/Security/Deleted) is
  /// showing: just the sidebar toggle — none of the list/detail column chrome applies to a
  /// single full-width view, which already renders its own title/count/actions in its content.
  private var fullWidthItemIdentifiers: [NSToolbarItem.Identifier] {
    [.toggleSidebar, .sidebarTrackingSeparator]
  }

  /// Adds or removes the list/detail-column toolbar items to match whether a full-width category
  /// view is showing — see `isFullWidthModeActive`'s documentation. Safe to call before
  /// `makeToolbar()`/before the toolbar is installed on the window (a no-op until then); the next
  /// `makeToolbar()` picks up the current mode via `toolbarDefaultItemIdentifiers(_:)`.
  func setFullWidthModeActive(_ active: Bool) {
    guard isFullWidthModeActive != active else { return }
    isFullWidthModeActive = active
    guard let toolbar else { return }

    let targetIdentifiers = active ? fullWidthItemIdentifiers : splitViewItemIdentifiers

    // Remove first (highest index first, so earlier removals don't shift later indices), then
    // insert whatever's missing at its target position — by the time the insert loop reaches
    // index `i`, every earlier index already matches `targetIdentifiers` by construction, so
    // comparing directly against `toolbar.items[i]` is safe.
    for index in stride(from: toolbar.items.count - 1, through: 0, by: -1) {
      if !targetIdentifiers.contains(toolbar.items[index].itemIdentifier) {
        toolbar.removeItem(at: index)
      }
    }
    for (index, identifier) in targetIdentifiers.enumerated() {
      if index >= toolbar.items.count || toolbar.items[index].itemIdentifier != identifier {
        toolbar.insertItem(withItemIdentifier: identifier, at: index)
      }
    }
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
      // Since macOS 26 ("Tahoe"), NSToolbar puts a Liquid Glass "platter" behind every item by
      // default — appropriate for interactive controls (buttons, the search field), but Apple's
      // own WWDC25 guidance ("Build an AppKit app with the new design") explicitly calls out
      // non-interactive custom titles as a case that should opt out via `isBordered = false`.
      // Without this, the category name/count rendered inside a gray glass capsule instead of
      // plain text (851-2463 review feedback), unlike Apple Passwords' own toolbar title.
      item.isBordered = false
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
