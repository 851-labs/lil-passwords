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
    let tint = palette[abs(item.id.hashValue) % palette.count]
    let symbolName = item.totp != nil ? "key.fill" : "lock.fill"
    return SidebarIconFactory.icon(symbolName: symbolName, tint: tint, dimension: dimension)
  }
}
