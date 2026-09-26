import AppKit
import LilPasswordsKit

/// The detail column: shows the selected item, or an empty state when nothing is selected.
///
/// There's no real selection/list infrastructure yet (that's 851-2415), so `show(item:)` is an
/// interim addition (851-2416) just for "select the new item after saving" — it renders a
/// non-editable `ItemPreviewView` rather than participating in any real selection model.
/// `select(category:)` exists so the split view can tell this controller what's showing without
/// either side needing to know about a concrete item type.
@MainActor
final class DetailViewController: NSViewController {
  private let emptyStateView = EmptyStateView()
  private let itemPreviewView = ItemPreviewView()

  override func loadView() {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    emptyStateView.translatesAutoresizingMaskIntoConstraints = false
    itemPreviewView.translatesAutoresizingMaskIntoConstraints = false
    itemPreviewView.isHidden = true
    view.addSubview(emptyStateView)
    view.addSubview(itemPreviewView)
    NSLayoutConstraint.activate([
      emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      emptyStateView.topAnchor.constraint(equalTo: view.topAnchor),
      emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      itemPreviewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      itemPreviewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      itemPreviewView.topAnchor.constraint(equalTo: view.topAnchor),
      itemPreviewView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    self.view = view
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    showNoSelection(for: .all)
  }

  /// Called by `MainSplitViewController` when the sidebar selection changes, so the empty
  /// state's wording can match ("No Password Selected" vs. "No Passkey Selected", etc).
  func showNoSelection(for category: SidebarCategory) {
    itemPreviewView.isHidden = true
    emptyStateView.isHidden = false
    emptyStateView.configure(
      symbolName: category.symbolName,
      title: "No \(singularNoun(for: category)) Selected",
      message: nil
    )
  }

  /// Shows `item` in place of the empty state — used right after 851-2416's New Password sheet
  /// saves, to satisfy "select the new item."
  func show(item: PasswordItem) {
    emptyStateView.isHidden = true
    itemPreviewView.isHidden = false
    itemPreviewView.configure(item: item)
  }

  private func singularNoun(for category: SidebarCategory) -> String {
    switch category {
    case .all: "Password"
    case .passkeys: "Passkey"
    case .codes: "Code"
    case .wifi: "Network"
    case .security: "Item"
    case .deleted: "Item"
    }
  }
}
