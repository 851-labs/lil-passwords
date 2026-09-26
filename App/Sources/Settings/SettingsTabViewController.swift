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
}
