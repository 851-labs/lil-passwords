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
  /// Builds a snapshot from real items (851-2414/851-2417/851-2419), computing sidebar counts for
  /// the categories `PasswordItem` currently models, plus the Wi-Fi category's known-network count
  /// (851-2444) and the Passkeys category's count (851-2442) — both sourced separately, from
  /// `WiFiNetworkViewModel.networks`/`PasskeysViewModel.passkeys`, since neither known Wi-Fi
  /// networks nor passkeys are `PasswordItem`s.
  init(items: [PasswordItem], wifiKnownNetworkCount: Int = 0, passkeyCount: Int = 0) {
    self.init(
      counts: [
        .all: items.nonDeleted().count,
        .codes: items.withVerificationCode().count,
        // The Security badge (851-2419) counts distinct flagged items, not distinct findings —
        // one item flagged as both reused and weak still only counts once.
        .security: SecurityFindings.build(from: items).uniqueItemIDs.count,
        .deleted: items.recentlyDeleted().count,
        .wifi: wifiKnownNetworkCount,
        .passkeys: passkeyCount,
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
