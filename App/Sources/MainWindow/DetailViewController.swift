import AppKit
import LilPasswordsKit

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

  /// Called by `MainSplitViewController` when the item list's selection changes to exactly one
  /// item. This is a placeholder — 851-2415 owns the real detail view and will replace this
  /// wholesale once it lands; it exists so 851-2414/851-2417 have something to drive selection
  /// into in the meantime.
  func show(item: PasswordItem) {
    let subtitle = item.usernames.first(where: { !$0.isEmpty })
    emptyStateView.configure(symbolName: "key.fill", title: item.title, message: subtitle)
  }

  /// Called by `MainSplitViewController` when the item list's selection contains more than one
  /// item. Also a placeholder for 851-2415.
  func showMultipleSelection(count: Int) {
    emptyStateView.configure(symbolName: "checkmark.circle.fill", title: "\(count) Items Selected", message: nil)
  }
}
