import Combine
import Foundation
import LilPasswordsKit

/// A lightweight, read-only summary of "how many items are in each sidebar category right now."
///
/// This exists so the sidebar, split view, and toolbar can be built and tested today against a
/// stand-in data source, before `PasswordItem` (851-2403) lands. Once the real vault store
/// exists, it should publish `VaultSnapshot` values instead of this file's `.empty` placeholder;
/// nothing in MainWindow/ needs to change beyond that wiring.
struct VaultSnapshot: Hashable, Sendable {
  /// A shared group of passwords (e.g. a family). Hidden from the sidebar until at least one
  /// exists, per 851-2413.
  struct SharedGroup: Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let itemCount: Int
  }

  var counts: [SidebarCategory: Int]
  var sharedGroups: [SharedGroup]

  static let empty = VaultSnapshot(counts: [:], sharedGroups: [])

  func count(for category: SidebarCategory) -> Int {
    counts[category] ?? 0
  }
}

extension VaultSnapshot {
  /// Builds a snapshot from real items (851-2414/851-2417), computing sidebar counts for the
  /// categories `PasswordItem` currently models. `passkeys`, `wifi`, and `security` aren't
  /// represented by `PasswordItem` yet, so they're left at their default zero count.
  init(items: [PasswordItem]) {
    self.init(
      counts: [
        .all: items.filter { $0.deletedAt == nil }.count,
        .codes: items.filter { $0.deletedAt == nil && $0.totpURI != nil }.count,
        .deleted: items.filter { $0.deletedAt != nil }.count,
      ],
      sharedGroups: []
    )
  }
}

/// Publishes the current `VaultSnapshot`. A view model, not a data store: it holds no
/// persistence logic of its own, only the latest snapshot handed to it by whatever eventually
/// reads the real vault.
@MainActor
final class VaultSnapshotStore: ObservableObject {
  @Published private(set) var snapshot: VaultSnapshot

  init(snapshot: VaultSnapshot = .empty) {
    self.snapshot = snapshot
  }

  func update(_ snapshot: VaultSnapshot) {
    self.snapshot = snapshot
  }
}
