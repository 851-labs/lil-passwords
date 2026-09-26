import AppKit

/// The detail column: shows the selected item, or an empty state when nothing is selected.
///
/// There's no real item to show yet (`PasswordItem` is 851-2403), so this always renders the
/// "nothing selected" empty state. `select(category:)` exists so the split view can tell this
/// controller what's showing without either side needing to know about a concrete item type.
@MainActor
final class DetailViewController: NSViewController {
  private let emptyStateView = EmptyStateView()

  override func loadView() {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    emptyStateView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(emptyStateView)
    NSLayoutConstraint.activate([
      emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      emptyStateView.topAnchor.constraint(equalTo: view.topAnchor),
      emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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
    emptyStateView.configure(
      symbolName: category.symbolName,
      title: "No \(singularNoun(for: category)) Selected",
      message: nil
    )
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
