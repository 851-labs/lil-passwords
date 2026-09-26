import AppKit

/// Arranges the three Settings tabs — General, Security, Agents — in a toolbar-style
/// `NSTabViewController`, the same presentation System Settings uses: a segmented toolbar control
/// switches tabs, and the window resizes to fit each tab's `preferredContentSize`.
@MainActor
final class SettingsTabViewController: NSTabViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    tabStyle = .toolbar
    canPropagateSelectedChildViewControllerTitle = false

    addTab(GeneralSettingsViewController(), title: "General", symbolName: "gearshape")
    addTab(SecuritySettingsViewController(), title: "Security", symbolName: "lock.shield")
    addTab(AgentsSettingsViewController(), title: "Agents", symbolName: "sparkles")
  }

  private func addTab(_ viewController: NSViewController, title: String, symbolName: String) {
    let tabViewItem = NSTabViewItem(viewController: viewController)
    tabViewItem.label = title
    tabViewItem.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
    addTabViewItem(tabViewItem)
  }

  // `NSTabViewController` doesn't automatically resize the window to match the newly-selected
  // child's `preferredContentSize` on every switch — only the initially-selected tab's size
  // reliably takes effect. Without this, switching to a taller tab (Agents, with its access-log
  // table) leaves the window stuck at whichever tab loaded first and clips the extra content.
  override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
    super.tabView(tabView, didSelect: tabViewItem)
    if let size = tabViewItem?.viewController?.preferredContentSize, size != .zero {
      preferredContentSize = size
    }
  }
}
