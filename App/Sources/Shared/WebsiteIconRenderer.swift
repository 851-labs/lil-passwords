import AppKit
import LilPasswordsKit

/// Clips a real, fetched website icon (851-2459) to the same rounded square `MonogramIcon` draws,
/// so a favicon and a generated monogram are visually interchangeable at every render site
/// (851-2467) — the item list, the detail pane header, the menu bar item detail, and the New
/// Password sheet, via `WebsiteIconLoader.loadIcon(forHost:dimension:onIconLoaded:)`.
///
/// Fixes three things a raw decoded `IconFetcher` image has that `MonogramIcon` never did:
///
/// 1. **Hard corners.** A raw favicon (Amazon, Dropbox, Etsy) is a plain square; this clips it to
///    ``MonogramIcon/cornerRadiusFraction``, the exact same corner radius ratio, so it reads as
///    the same shape as every monogram around it.
/// 2. **Edge-to-edge transparent glyphs.** Icons like Apple's, Bank of America's, or Figma's ship
///    as a mostly-transparent PNG with a small glyph in the middle. Drawn straight into a
///    hard-edged tile, the glyph looks like it's floating with nothing behind it, and whatever's
///    beneath (list row background, selection highlight) shows through unevenly. Icons small
///    enough to look soft when stretched to fill the tile have the same problem. Both get a flat
///    neutral tile behind them instead, with the icon inset ``tileInsetFraction`` per side —
///    matching Apple Passwords' own treatment of icons like "Sign in with Apple".
/// 3. **No border.** A white or near-white icon has no edge against a white/near-white list
///    background in light mode. A hairline stroke fixes that — light mode only, since dark
///    backgrounds already give every tile enough contrast and Apple Passwords doesn't stroke
///    tiles in dark mode either.
@MainActor
enum WebsiteIconRenderer {
  /// How far a tiled icon (see the type doc) is inset from each edge of its tile, as a fraction
  /// of the tile's side length.
  private static let tileInsetFraction: CGFloat = 0.15

  /// Below this fraction of opaque border pixels (sampled on a small grid, see
  /// `hasTransparentEdges(_:)`), an icon reads as a small glyph floating on transparency rather
  /// than artwork that fills its own square — it gets a neutral tile instead of an edge-to-edge
  /// clip.
  private static let transparentEdgeThreshold: CGFloat = 0.65

  /// Below this fraction of the crisp-at-2x pixel size an icon would need at `dimension`, it's
  /// treated as too small to stretch edge-to-edge without looking soft, and gets the same neutral
  /// tile treatment as a transparent-edged icon.
  private static let smallSourceThreshold: CGFloat = 0.6

  /// The tile's hairline border, light mode only (see the type doc, point 3). A flat black at low
  /// alpha reads as a hairline against any tile fill color, the same way `NSColor.separatorColor`
  /// would, without needing this bitmap-baked render to resolve a semantic dynamic color outside
  /// of any window's real drawing context.
  private static let borderColor = NSColor(white: 0, alpha: 0.12)

  /// Renders `source` (whatever `IconFetcher`/`IconStore` decoded) into a fresh `dimension` ×
  /// `dimension` square: clipped to `MonogramIcon`'s rounded corners, tiled + inset if it's
  /// transparent-edged or too small to fill the square crisply, and given a light-mode-only
  /// hairline border. Reads the current effective appearance once, at render time — matching
  /// `MonogramIcon`, this bakes a static bitmap rather than staying live if the appearance changes
  /// while it's already on screen.
  static func render(_ source: NSImage, dimension: CGFloat) -> NSImage {
    let needsTile = needsNeutralTile(source, dimension: dimension)
    let dark = isDarkMode()

    let image = NSImage(size: NSSize(width: dimension, height: dimension), flipped: false) { rect in
      NSGraphicsContext.current?.imageInterpolation = .high

      let cornerRadius = rect.width * MonogramIcon.cornerRadiusFraction
      let clipPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

      NSGraphicsContext.saveGraphicsState()
      clipPath.addClip()

      let contentRect: NSRect
      if needsTile {
        neutralTileColor(darkMode: dark).setFill()
        clipPath.fill()
        let inset = rect.width * tileInsetFraction
        contentRect = rect.insetBy(dx: inset, dy: inset)
      } else {
        contentRect = rect
      }
      source.draw(in: contentRect, from: .zero, operation: .sourceOver, fraction: 1)
      NSGraphicsContext.restoreGraphicsState()

      if !dark {
        let strokeInset: CGFloat = 0.5
        let strokeRect = rect.insetBy(dx: strokeInset, dy: strokeInset)
        let strokeRadius = max(cornerRadius - strokeInset, 0)
        let strokePath = NSBezierPath(roundedRect: strokeRect, xRadius: strokeRadius, yRadius: strokeRadius)
        strokePath.lineWidth = 1
        borderColor.setStroke()
        strokePath.stroke()
      }
      return true
    }
    image.isTemplate = false
    return image
  }

  /// Whether `NSApp`'s current effective appearance resolves to dark — read once per `render`
  /// call (see that method's doc comment for why this isn't kept live).
  private static func isDarkMode() -> Bool {
    NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
  }

  private static func neutralTileColor(darkMode: Bool) -> NSColor {
    darkMode ? NSColor(white: 0.30, alpha: 1) : NSColor(white: 0.90, alpha: 1)
  }

  /// True if `source` should sit on a neutral tile with inset padding rather than get clipped
  /// edge-to-edge — either because it's mostly transparent near its own edges (a small glyph, not
  /// artwork that fills its square) or because its native pixel size is too small to stay crisp
  /// stretched to `dimension` at 2x.
  private static func needsNeutralTile(_ source: NSImage, dimension: CGFloat) -> Bool {
    guard let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return true }

    if hasTransparentEdges(cgImage) { return true }

    let targetPixelSize = dimension * 2
    let nativeMaxSide = CGFloat(max(cgImage.width, cgImage.height))
    return nativeMaxSide < targetPixelSize * smallSourceThreshold
  }

  /// Draws `cgImage` into a small, fixed-size sampling grid and checks what fraction of the
  /// pixels on that grid's outer ring are opaque. A real edge-to-edge icon (a solid-color app
  /// tile like Amazon's or Dropbox's) reads as fully opaque all the way to its own edges; a
  /// small centered glyph on a transparent background (Apple's, Bank of America's, Figma's) reads
  /// as mostly transparent on that same ring — see ``transparentEdgeThreshold``.
  private static func hasTransparentEdges(_ cgImage: CGImage) -> Bool {
    let sampleSize = 16
    guard
      let context = CGContext(
        data: nil,
        width: sampleSize,
        height: sampleSize,
        bitsPerComponent: 8,
        bytesPerRow: sampleSize * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ),
      let data = context.data
    else { return false }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
    let buffer = data.bindMemory(to: UInt8.self, capacity: sampleSize * sampleSize * 4)

    var opaqueEdgeCount = 0
    var edgeCount = 0
    for y in 0..<sampleSize {
      for x in 0..<sampleSize {
        guard x == 0 || y == 0 || x == sampleSize - 1 || y == sampleSize - 1 else { continue }
        edgeCount += 1
        let alpha = buffer[(y * sampleSize + x) * 4 + 3]
        if alpha > 200 { opaqueEdgeCount += 1 }
      }
    }
    guard edgeCount > 0 else { return false }
    return CGFloat(opaqueEdgeCount) / CGFloat(edgeCount) < transparentEdgeThreshold
  }
}
