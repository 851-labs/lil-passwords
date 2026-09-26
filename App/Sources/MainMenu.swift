import AppKit
import LilPasswordsKit

/// Minimal main menu. The full menu set arrives in 851-2424.
@MainActor
enum MainMenu {
  static func make() -> NSMenu {
    let mainMenu = NSMenu()
    let name = LilPasswordsKit.productName

    let appMenu = NSMenu(title: name)
    appMenu.addItem(
      withTitle: "About \(name)",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: ""
    )
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    addSubmenu(appMenu, to: mainMenu)

    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    addSubmenu(windowMenu, to: mainMenu)
    NSApp.windowsMenu = windowMenu

    return mainMenu
  }

  private static func addSubmenu(_ submenu: NSMenu, to menu: NSMenu) {
    let item = NSMenuItem()
    item.submenu = submenu
    menu.addItem(item)
  }
}
