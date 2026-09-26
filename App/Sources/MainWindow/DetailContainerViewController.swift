import AppKit

/// Hosts exactly one child view controller at a time, filling its own view entirely, and swaps
/// that child via `addChild`/`removeFromParent` + view-hierarchy swapping.
///
/// `MainSplitViewController`'s `detailItem` is set to an instance of this container once, in
/// `viewDidLoad`, and never reassigned again — `NSSplitViewItem.viewController` throws an
/// (uncaught, silently-swallowed-by-AppKit's-event-loop) exception if it's set to a *different*
/// view controller after the item has already been added to the split view controller, which is
/// exactly what selecting Codes/Security/Deleted used to do (swapping `detailItem.viewController`
/// directly between `detailViewController` and the full-width controllers). Swapping this
/// container's child instead sidesteps that restriction entirely.
final class DetailContainerViewController: NSViewController {
  private(set) var contentViewController: NSViewController?

  override func loadView() {
    view = NSView()
  }

  /// Replaces the currently-hosted child with `viewController`, a no-op if it's already hosted.
  func setContentViewController(_ viewController: NSViewController) {
    guard contentViewController !== viewController else { return }

    if let current = contentViewController {
      current.view.removeFromSuperview()
      current.removeFromParent()
    }

    addChild(viewController)
    let childView = viewController.view
    childView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(childView)
    NSLayoutConstraint.activate([
      childView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      childView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      childView.topAnchor.constraint(equalTo: view.topAnchor),
      childView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    contentViewController = viewController
  }
}
