import AppKit
import LilPasswordsKit

/// Owns the app's `NSStatusItem` and its popover (851-2425), matching Apple Passwords' own menu
/// bar extra: a template "key" glyph that toggles a popover containing search/Suggested/detail
/// (`MenuBarRootViewController`).
///
/// Visibility follows `AppSettings.showInMenuBar` (Settings → General → "Show in menu bar", on by
/// default) live — toggling it in Settings shows or hides the status item immediately, without
/// requiring a relaunch, by observing `AppSettings.didChangeNotification` the same way other
/// Settings-backed UI in this app does.
@MainActor
final class MenuBarExtraController: NSObject {
  private var statusItem: NSStatusItem?
  private let popover = NSPopover()
  private let rootViewController: MenuBarRootViewController
  private var settingsObserver: NSObjectProtocol?

  init(vaultViewModel: VaultViewModel, lockCoordinator: LockCoordinator, openMainWindow: @escaping () -> Void) {
    rootViewController = MenuBarRootViewController(
      vaultViewModel: vaultViewModel,
      lockCoordinator: lockCoordinator,
      openMainWindow: openMainWindow
    )
    super.init()

    popover.behavior = .transient
    popover.contentViewController = rootViewController
    popover.contentSize = MenuBarRootViewController.popoverSize

    applyVisibility()
    settingsObserver = NotificationCenter.default.addObserver(
      forName: AppSettings.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.applyVisibility() }
    }
  }

  isolated deinit {
    if let settingsObserver {
      NotificationCenter.default.removeObserver(settingsObserver)
    }
  }

  private func applyVisibility() {
    if AppSettings.shared.showInMenuBar {
      showStatusItemIfNeeded()
    } else {
      hideStatusItem()
    }
  }

  private func showStatusItemIfNeeded() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      let image = NSImage(systemSymbolName: "key", accessibilityDescription: LilPasswordsKit.productName)
      image?.isTemplate = true
      button.image = image
      button.target = self
      button.action = #selector(togglePopover)
    }
    statusItem = item
  }

  private func hideStatusItem() {
    guard let statusItem else { return }
    NSStatusBar.system.removeStatusItem(statusItem)
    self.statusItem = nil
    if popover.isShown {
      popover.performClose(nil)
    }
  }

  @objc private func togglePopover() {
    guard let button = statusItem?.button else { return }
    if popover.isShown {
      popover.performClose(nil)
      return
    }
    rootViewController.popoverWillShow()
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
  }
}
