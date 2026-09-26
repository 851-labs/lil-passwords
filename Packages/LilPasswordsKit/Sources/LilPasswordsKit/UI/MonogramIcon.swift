import AppKit

/// Draws the colored rounded-square monogram icons Apple Passwords shows next to each item in the
/// list when a site has no favicon: a flat tinted square with the item's first letter centered
/// inside it in white. Shared with 851-2459 (website icon fetching, see `WebsiteIconLoader`), which
/// falls back to this when no real icon is available or "Show website icons" is off.
///
/// 851-2441: moved here from the app target (`App/Sources/Shared/MonogramIcon.swift`) and made
/// `public` so the AutoFill credential provider extension's own list UI (`AutoFillExtension`,
/// sandboxed, a separate bundle from the app) can render the exact same monogram style as the
/// app's own item list — see ``CredentialRowView`` in this same directory, which is the other half
/// of that shared-row-style move.
@MainActor
public enum MonogramIcon {
  private static var cache: [CacheKey: NSImage] = [:]

  private struct CacheKey: Hashable {
    let letter: String
    let tint: NSColor
    let dimension: CGFloat
  }

  /// The muted, evenly-spaced tint palette monogram squares are drawn from. Deliberately similar
  /// in saturation/lightness to each other so no single letter's color reads as more "important"
  /// than another's.
  private static let palette: [NSColor] = [
    NSColor(red: 0.90, green: 0.35, blue: 0.35, alpha: 1),  // red
    NSColor(red: 0.92, green: 0.55, blue: 0.20, alpha: 1),  // orange
    NSColor(red: 0.85, green: 0.68, blue: 0.15, alpha: 1),  // yellow
    NSColor(red: 0.40, green: 0.70, blue: 0.35, alpha: 1),  // green
    NSColor(red: 0.20, green: 0.65, blue: 0.60, alpha: 1),  // teal
    NSColor(red: 0.25, green: 0.55, blue: 0.85, alpha: 1),  // blue
    NSColor(red: 0.40, green: 0.45, blue: 0.85, alpha: 1),  // indigo
    NSColor(red: 0.60, green: 0.40, blue: 0.85, alpha: 1),  // purple
    NSColor(red: 0.85, green: 0.35, blue: 0.65, alpha: 1),  // pink
    NSColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1),  // gray
    NSColor(red: 0.35, green: 0.60, blue: 0.45, alpha: 1),  // mint
    NSColor(red: 0.75, green: 0.45, blue: 0.30, alpha: 1),  // brown
  ]

  /// The single uppercase letter drawn for `title`: its first letter, or "#" if it doesn't start
  /// with one (digits, symbols, emoji, or an empty title). Matches `PasswordItem.titleSectionKey`
  /// so a row's monogram always agrees with the section header it's grouped under.
  public static func letter(for title: String) -> String {
    guard let first = title.trimmingCharacters(in: .whitespacesAndNewlines).first, first.isLetter else {
      return "#"
    }
    return String(first).folding(options: .diacriticInsensitive, locale: nil).uppercased()
  }

  /// A stable tint for `title`, deterministically hashed into ``palette`` so the same title
  /// always gets the same color across launches, but different titles are spread across the
  /// whole palette rather than clustering. The hashing itself is ``MonogramPalette/colorIndex(for:paletteCount:)``
  /// — a fixed, unseeded FNV-1a hash, not Swift's `String.hashValue` (which is randomly reseeded
  /// every launch, so the same title used to get a different color each time the app ran). Kept as
  /// a public entry point via ``colorIndex(for:)`` below so other views can agree on the same
  /// color for a title without duplicating this palette.
  public static func tint(for title: String) -> NSColor {
    palette[colorIndex(for: title)]
  }

  /// The stable index into ``palette`` for `title` — see ``tint(for:)``. Exposed separately (in
  /// addition to `tint(for:)`) so callers that just need to agree on *which* color a title maps to
  /// (e.g. a test, or another view reusing this exact palette) don't need an `NSColor` comparison.
  public static func colorIndex(for title: String) -> Int {
    MonogramPalette.colorIndex(for: title, paletteCount: palette.count)
  }

  /// - Parameters:
  ///   - title: The item title the monogram represents; drives both the letter and the tint.
  ///   - dimension: Side length of the square, in points. List rows use 28pt.
  public static func icon(for title: String, dimension: CGFloat = 28) -> NSImage {
    let letter = letter(for: title)
    let tint = tint(for: title)
    let key = CacheKey(letter: letter, tint: tint, dimension: dimension)
    if let cached = cache[key] {
      return cached
    }

    let image = NSImage(size: NSSize(width: dimension, height: dimension), flipped: false) { rect in
      let cornerRadius = rect.width * 0.28
      let backgroundPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
      tint.setFill()
      backgroundPath.fill()

      let font = NSFont.systemFont(ofSize: dimension * 0.5, weight: .semibold)
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
      ]
      let attributedLetter = NSAttributedString(string: letter, attributes: attributes)
      let textSize = attributedLetter.size()
      let origin = NSPoint(
        x: rect.midX - textSize.width / 2,
        y: rect.midY - textSize.height / 2
      )
      attributedLetter.draw(at: origin)
      return true
    }
    image.isTemplate = false
    cache[key] = image
    return image
  }
}
