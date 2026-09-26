import AppKit
import LilPasswordsKit

/// Builds the app's full main menu bar: App, File, Edit, View, Window, and Help, matching Apple
/// Passwords' menu layout and keyboard shortcuts (851-2424).
///
/// Most items route through the responder chain with a `nil` target rather than a concrete
/// object, so whichever object is best positioned to handle an action — the focused text field
/// for `cut:`/`copy:`, the split view controller for `toggleSidebar:`, or a stub fallback on
/// `AppDelegate` (see `AppDelegate+MenuActions.swift`) when nothing real exists yet — gets first
/// crack at it. That means later tickets (e.g. 851-2416's new-password sheet, 851-2414's sorting)
/// can make an action "real" just by implementing the same `@objc` selector closer to the data;
/// nothing here needs to change.
@MainActor
enum MainMenu {
  static func make() -> NSMenu {
    let mainMenu = NSMenu()
    mainMenu.addSubmenu(makeAppMenu())
    mainMenu.addSubmenu(makeFileMenu())
    mainMenu.addSubmenu(makeEditMenu())
    mainMenu.addSubmenu(makeViewMenu())

    let windowMenu = makeWindowMenu()
    mainMenu.addSubmenu(windowMenu)
    NSApp.windowsMenu = windowMenu

    let helpMenu = makeHelpMenu()
    mainMenu.addSubmenu(helpMenu)
    NSApp.helpMenu = helpMenu

    return mainMenu
  }

  // MARK: - App menu

  private static func makeAppMenu() -> NSMenu {
    let name = LilPasswordsKit.productName
    let menu = NSMenu(title: name)

    menu.addItem(
      withTitle: "About \(name)",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: ""
    )
    // Sparkle (851-2437). See App/Sources/Updates/UpdaterController.swift.
    let checkForUpdatesItem = menu.addItem(
      withTitle: "Check for Updates…",
      action: #selector(UpdaterController.checkForUpdates(_:)),
      keyEquivalent: ""
    )
    checkForUpdatesItem.target = UpdaterController.shared
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Settings…",
      action: #selector(AppDelegate.showSettings(_:)),
      keyEquivalent: ","
    )
    menu.addItem(.separator())

    let servicesItem = menu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
    let servicesMenu = NSMenu(title: "Services")
    servicesItem.submenu = servicesMenu
    NSApp.servicesMenu = servicesMenu
    menu.addItem(.separator())

    menu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    menu.addItem(
      withTitle: "Hide Others",
      action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h"
    ).keyEquivalentModifierMask = [.command, .option]
    menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    menu.addItem(.separator())

    menu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    return menu
  }

  // MARK: - File menu

  private static func makeFileMenu() -> NSMenu {
    let menu = NSMenu(title: "File")

    menu.addItem(withTitle: "New Password", action: #selector(AppDelegate.newPassword(_:)), keyEquivalent: "n")
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Import Passwords…",
      action: #selector(AppDelegate.importPasswords(_:)),
      keyEquivalent: ""
    )
    menu.addItem(
      withTitle: "Export All Passwords…",
      action: #selector(AppDelegate.exportAllPasswords(_:)),
      keyEquivalent: ""
    )
    menu.addItem(.separator())
    menu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

    return menu
  }

  // MARK: - Edit menu

  private static func makeEditMenu() -> NSMenu {
    let menu = NSMenu(title: "Edit")

    // `undo:`/`redo:` have no compile-time-declared selector — NSUndoManager wires them up on
    // the responder chain dynamically — so these use the classic raw-selector form instead of
    // `#selector`, same as Xcode's own default menu template.
    menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    menu.addItem(.separator())

    // `NSText` (a `NSView` subclass every text field's field editor descends from) declares
    // `cut(_:)`/`copy(_:)`/`paste(_:)`/`delete(_:)`; referencing them here is only a way to name
    // the Objective-C selector; the `nil`-target action never actually reaches this class.
    menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    menu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
    menu.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
    menu.addItem(.separator())

    menu.addItem(withTitle: "Find", action: #selector(AppDelegate.find(_:)), keyEquivalent: "f")

    return menu
  }

  // MARK: - View menu

  private static func makeViewMenu() -> NSMenu {
    let menu = NSMenu(title: "View")

    menu.addItem(
      withTitle: "Show Sidebar",
      action: #selector(NSSplitViewController.toggleSidebar(_:)),
      keyEquivalent: "s"
    ).keyEquivalentModifierMask = [.command, .option]
    menu.addItem(.separator())

    let sortItem = menu.addItem(withTitle: "Sort By", action: nil, keyEquivalent: "")
    sortItem.submenu = makeSortByMenu()

    return menu
  }

  private static func makeSortByMenu() -> NSMenu {
    let menu = NSMenu(title: "Sort By")
    let byName = menu.addItem(withTitle: "Name", action: #selector(AppDelegate.sortByName(_:)), keyEquivalent: "")
    // Sorting isn't implemented yet (851-2414); "Name" is the only order the item list can show
    // today, so it's marked as the current choice until real sorting lands.
    byName.state = .on
    menu.addItem(
      withTitle: "Date Modified",
      action: #selector(AppDelegate.sortByDateModified(_:)),
      keyEquivalent: ""
    )
    menu.addItem(
      withTitle: "Date Created",
      action: #selector(AppDelegate.sortByDateCreated(_:)),
      keyEquivalent: ""
    )
    return menu
  }

  // MARK: - Window menu

  private static func makeWindowMenu() -> NSMenu {
    let menu = NSMenu(title: "Window")

    menu.addItem(
      withTitle: "Minimize",
      action: #selector(NSWindow.performMiniaturize(_:)),
      keyEquivalent: "m"
    )
    menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

    return menu
  }

  // MARK: - Help menu

  private static func makeHelpMenu() -> NSMenu {
    let name = LilPasswordsKit.productName
    let menu = NSMenu(title: "Help")
    menu.addItem(
      withTitle: "\(name) Help",
      action: #selector(NSApplication.showHelp(_:)),
      keyEquivalent: ""
    )
    return menu
  }
}

extension NSMenu {
  /// Wraps `submenu` in a top-level `NSMenuItem` and appends it, mirroring how `NSMenu` items
  /// with submenus are built throughout this file.
  fileprivate func addSubmenu(_ submenu: NSMenu) {
    let item = NSMenuItem()
    item.title = submenu.title
    item.submenu = submenu
    addItem(item)
  }
}
