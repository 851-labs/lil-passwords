import AppKit

/// The content column: the list of items for the selected sidebar category.
///
/// `PasswordItem` (851-2403) doesn't exist yet, so this controller only knows how to render an
/// empty state per `SidebarCategory`. The list itself (an `NSTableView` bound to real items) is
/// intentionally left for whoever wires the item model in; this controller's public surface
/// (`select(category:)`) is what that change should hook into instead of restructuring the
/// split view.
@MainActor
final class ItemListViewController: NSViewController {
  private let emptyStateView = EmptyStateView()
  private let store: VaultSnapshotStore
  private var currentCategory: SidebarCategory = .all

  init(store: VaultSnapshotStore) {
    self.store = store
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

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
    updateEmptyState()
  }

  /// Called by `MainSplitViewController` when the sidebar selection changes.
  func select(category: SidebarCategory) {
    currentCategory = category
    updateEmptyState()
  }

  private func updateEmptyState() {
    // Every category is empty until the real item model is wired in, so this is unconditional
    // for now. Once there's a real count, this should branch on `store.snapshot.count(for:)`.
    emptyStateView.configure(
      symbolName: currentCategory.symbolName,
      title: currentCategory.emptyListTitle,
      message: currentCategory.emptyListMessage
    )
  }
}
