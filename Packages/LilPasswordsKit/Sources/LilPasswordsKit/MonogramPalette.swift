import Foundation

/// Deterministically maps an item title to a stable index into a monogram color palette.
///
/// The actual palette (a list of `NSColor`s) lives in the App target's `MonogramIcon`, since
/// `LilPasswordsKit` stays AppKit-free so it can be used from the CLI/Agent too — this type only
/// computes *which* index a title should use, so the item list and the detail pane header (851-2414,
/// detail PR #14) agree on a title's color without either one owning the other's UI code.
///
/// Deliberately not Swift's `String.hashValue`: that's seeded randomly every process launch (to
/// resist hash-flooding attacks), so the same title would map to a different color each time the
/// app runs — the exact bug this type exists to fix. `hashValue` also isn't guaranteed stable
/// across Swift versions even within a single launch. FNV-1a over the title's lowercased UTF-8
/// bytes is a fixed, well-known algorithm with no seeding and no signed-overflow trap risk (unlike
/// the previous `abs(title.hashValue)`, which trapped for `Int.min`).
public enum MonogramPalette {
  private static let fnvOffsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
  private static let fnvPrime: UInt64 = 0x0000_0100_0000_01b3

  /// A stable index in `0..<paletteCount` for `title`, computed via FNV-1a over the lowercased
  /// title's UTF-8 bytes. The same `(title, paletteCount)` pair always returns the same index, in
  /// this process and in any other — across launches, across platforms, and across Swift versions.
  ///
  /// - Parameters:
  ///   - title: The item title to hash. Lowercased first, so "Amazon" and "amazon" land on the
  ///     same color.
  ///   - paletteCount: The number of colors in the caller's palette. Must be positive.
  public static func colorIndex(for title: String, paletteCount: Int) -> Int {
    precondition(paletteCount > 0, "paletteCount must be positive")

    var hash = fnvOffsetBasis
    for byte in title.lowercased().utf8 {
      hash ^= UInt64(byte)
      hash = hash &* fnvPrime
    }

    return Int(hash % UInt64(paletteCount))
  }
}
