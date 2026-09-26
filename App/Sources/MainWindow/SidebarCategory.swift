import AppKit

/// The fixed set of top-level sidebar categories, matching Apple Passwords' source list.
///
/// `PasswordItem` (851-2403) is being built in parallel, so this enum and the rest of the
/// main window intentionally know nothing about the real item model yet. Counts are supplied
/// by a `VaultSnapshot` (see VaultSnapshot.swift) so a future change can wire in real data
/// without touching the sidebar or split view controllers.
enum SidebarCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
  case all
  case passkeys
  case codes
  case wifi
  case security
  case deleted

  var id: String { rawValue }

  /// Title shown in the sidebar row.
  var title: String {
    switch self {
    case .all: "All"
    case .passkeys: "Passkeys"
    case .codes: "Codes"
    case .wifi: "Wi-Fi"
    case .security: "Security"
    case .deleted: "Deleted"
    }
  }

  /// SF Symbol drawn inside the colored rounded-square icon, matching Apple Passwords.
  var symbolName: String {
    switch self {
    case .all: "key.fill"
    case .passkeys: "person.badge.key.fill"
    case .codes: "lock.rotation"
    case .wifi: "wifi"
    case .security: "exclamationmark.shield.fill"
    case .deleted: "trash.fill"
    }
  }

  /// Background tint of the rounded-square icon, matching Apple's System Settings-style
  /// colored glyphs.
  var tintColor: NSColor {
    switch self {
    case .all: .systemGray
    case .passkeys: .systemBlue
    case .codes: .systemGreen
    case .wifi: .systemBlue
    case .security: .systemRed
    case .deleted: .systemGray
    }
  }

  /// Title of the empty state shown in the item list when this category has no items.
  var emptyListTitle: String {
    switch self {
    case .all: "No Passwords"
    case .passkeys: "No Passkeys"
    case .codes: "No Verification Codes"
    case .wifi: "No Wi-Fi Passwords"
    case .security: "No Security Recommendations"
    case .deleted: "No Recently Deleted Items"
    }
  }

  /// Subtitle shown under the empty state title in the item list.
  var emptyListMessage: String {
    switch self {
    case .all: "Passwords and passkeys you save will appear here."
    case .passkeys: "Passkeys you save will appear here."
    case .codes: "Verification codes you save will appear here."
    case .wifi: "Wi-Fi networks you save will appear here."
    case .security: "Lil Passwords will let you know about weak, reused, or leaked passwords."
    case .deleted: "Items you delete will appear here for 30 days."
    }
  }
}
