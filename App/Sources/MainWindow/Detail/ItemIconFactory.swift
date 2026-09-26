import AppKit
import LilPasswordsKit

/// The large icon shown in the detail pane header for a single item.
///
/// Apple Passwords shows each site's actual favicon here, but fetching one would mean a network
/// request keyed off vault data — explicitly out of scope for v0.1 (see the project's "no
/// favicon fetching" decision). This draws the same colored rounded-square glyph the sidebar
/// uses instead, picking a tint from a stable hash of the item's id so a list of items reads as
/// visually distinct without implying any particular site.
@MainActor
enum ItemIconFactory {
  private static let palette: [NSColor] = [
    .systemBlue, .systemGreen, .systemIndigo, .systemOrange,
    .systemPink, .systemPurple, .systemRed, .systemTeal,
  ]

  static func icon(for item: PasswordItem, dimension: CGFloat = 64) -> NSImage {
    let tint = palette[stableIndex(for: item.id, count: palette.count)]
    let symbolName = item.totp != nil ? "key.fill" : "lock.fill"
    return SidebarIconFactory.icon(symbolName: symbolName, tint: tint, dimension: dimension)
  }

  /// A deterministic index derived from `id`'s raw bytes (FNV-1a), used instead of `UUID
  /// .hashValue`. `Hashable.hashValue` is deliberately seeded per-process for hash-flooding
  /// resistance, so the same item's id would hash to a different value — and thus a different
  /// palette color — on every relaunch. That made the header icon appear to change color between
  /// otherwise-identical read-mode and edit-mode screenshots that just happened to be captured
  /// from different app launches. Hashing the id's bytes ourselves keeps the color pinned to the
  /// item, not to the process.
  private static func stableIndex(for id: UUID, count: Int) -> Int {
    let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    let prime: UInt64 = 0x0000_0100_0000_01b3
    var hash = offsetBasis
    withUnsafeBytes(of: id.uuid) { bytes in
      for byte in bytes {
        hash ^= UInt64(byte)
        hash = hash &* prime
      }
    }
    return Int(hash % UInt64(count))
  }
}
