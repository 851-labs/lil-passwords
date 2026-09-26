import Foundation
import LilPasswordsKit

/// Fetches and filters access-log entries for `AgentsSettingsView` (851-2429), reading the same
/// on-disk JSONL file `LilPasswordsAgent`'s `AccessLogStore` writes — see that type's
/// documentation for why the app reads the file directly instead of asking the helper over XPC.
@MainActor
final class AccessLogViewModel: ObservableObject {
  /// Already sorted newest-first and filtered by ``filterText`` — what `AgentsSettingsView`'s
  /// table actually renders.
  @Published private(set) var entries: [AccessLogEntry] = []

  @Published var filterText: String = "" {
    didSet { applyFilter() }
  }

  private var allEntries: [AccessLogEntry] = []
  private let store: AccessLogStore?

  /// `store` is `nil` only if `AccessLogStore.defaultFileURL`'s Application Support lookup itself
  /// fails (an unwritable/inaccessible home directory) — the same "keep the rest of the app
  /// working" fallback `Agent/Sources/main.swift` uses. The pane then just shows an empty log
  /// rather than crashing Settings.
  init(store: AccessLogStore? = try? AccessLogStore()) {
    self.store = store
  }

  func refresh() async {
    guard let store else { return }
    allEntries = await store.fetchAll().sorted { $0.date > $1.date }
    applyFilter()
  }

  func clear() async {
    guard let store else { return }
    try? await store.clear()
    await refresh()
  }

  private func applyFilter() {
    let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      entries = allEntries
      return
    }
    entries = allEntries.filter { entry in
      entry.operation.localizedCaseInsensitiveContains(query)
        || entry.callerDescription.localizedCaseInsensitiveContains(query)
        || (entry.itemTitle?.localizedCaseInsensitiveContains(query) ?? false)
        || entry.fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }
  }
}
