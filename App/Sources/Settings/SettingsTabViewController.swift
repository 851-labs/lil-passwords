import AppKit

/// Arranges the three Settings tabs — General, Security, Agents — in a toolbar-style
/// `NSTabViewController`, the same presentation System Settings uses: a segmented toolbar control
/// switches tabs, and the window resizes to fit each tab's `preferredContentSize`.
@MainActor
final class SettingsTabViewController: NSTabViewController {
  /// One case per tab, in display order — also the accepted `-OpenSettingsTab` raw values (see
  /// `AppDelegate.applyOpenSettingsTabOverrideIfNeeded()`), so a DEBUG launch argument and this
  /// controller's own tab order can't drift apart.
  enum Tab: String {
    case general
    case security
    case agents
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    tabStyle = .toolbar
    canPropagateSelectedChildViewControllerTitle = false

    addTab(GeneralSettingsViewController(), title: "General", symbolName: "gearshape")
    addTab(SecuritySettingsViewController(), title: "Security", symbolName: "lock.shield")
    addTab(AgentsSettingsViewController(), title: "Agents", symbolName: "sparkles")

    // `addTabViewItem` above auto-selects index 0 (General), but that selection happens without
    // going through `tabView(_:didSelect:)` below, so nothing has sized the window for it yet.
    // Do that once up front so the window opens at the right size even before the user (or a
    // `-OpenSettingsTab` launch) ever triggers a tab switch.
    if let selected = tabViewItems[selectedTabViewItemIndex].viewController {
      resizeToFitContent(of: selected)
    }
  }

  private func addTab(_ viewController: NSViewController, title: String, symbolName: String) {
    let tabViewItem = NSTabViewItem(viewController: viewController)
    tabViewItem.label = title
    tabViewItem.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
    addTabViewItem(tabViewItem)
  }

  /// Selects a tab by its stable identifier rather than a positional index, so callers (currently
  /// just `AppDelegate`'s `-OpenSettingsTab` override) don't have to know tab order.
  func selectTab(_ tab: Tab) {
    guard let index = tabViewItems.firstIndex(where: { tabIdentifier(for: $0) == tab }) else { return }
    selectedTabViewItemIndex = index
  }

  private func tabIdentifier(for tabViewItem: NSTabViewItem) -> Tab? {
    switch tabViewItem.viewController {
    case is GeneralSettingsViewController: return .general
    case is SecuritySettingsViewController: return .security
    case is AgentsSettingsViewController: return .agents
    default: return nil
    }
  }

  // `NSTabViewController` doesn't automatically resize the window to match the newly-selected
  // child's content size on every switch — only the initially-selected tab's size reliably takes
  // effect. Without this, switching to a taller tab (Agents, with its access-log table) leaves the
  // window stuck at whichever tab loaded first and clips the extra content.
  override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
    super.tabView(tabView, didSelect: tabViewItem)
    guard let viewController = tabViewItem?.viewController else { return }
    resizeToFitContent(of: viewController)
  }

  // Resizes the window to fit `viewController`'s actual SwiftUI content, in place of reading its
  // `preferredContentSize` (which each tab's `NSHostingController` never populates in practice:
  // `sizingOptions = [.intrinsicContentSize]` keeps that hosting controller's own `view.frame` /
  // `fittingSize` correctly tracking its SwiftUI content, but doesn't forward that into
  // `preferredContentSize` for a hosting controller nested under another view controller, only for
  // one set directly as a window's `contentViewController`. Reading `preferredContentSize` here
  // instead silently read `.zero`, which is why the window used to sit at whatever default size
  // `NSWindow(contentViewController:)` picked (500×500-ish) regardless of tab or content.
  //
  // `layoutSubtreeIfNeeded()` matters, not just cosmetically: the newly-selected child's view has
  // just been swapped into the tab view's content area, but AppKit doesn't necessarily run its
  // layout pass (and, for the `NSHostingController`, recompute `fittingSize` from SwiftUI's actual
  // content) until the next display cycle. Reading `fittingSize` before forcing that layout pass
  // would read a stale value.
  private func resizeToFitContent(of viewController: NSViewController) {
    viewController.view.layoutSubtreeIfNeeded()
    let size = viewController.view.fittingSize
    guard size != .zero else { return }
    preferredContentSize = size
  }
}
