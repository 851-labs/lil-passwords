import AppKit

/// Draws the colored rounded-square glyphs Apple uses for sidebar/System Settings-style icons:
/// a flat tinted square with a white SF Symbol centered inside it.
@MainActor
enum SidebarIconFactory {
  private static var cache: [CacheKey: NSImage] = [:]

  private struct CacheKey: Hashable {
    let symbolName: String
    let tint: NSColor
    let dimension: CGFloat
  }

  /// - Parameters:
  ///   - symbolName: SF Symbol name drawn in white inside the square.
  ///   - tint: Background color of the rounded square.
  ///   - dimension: Side length of the square, in points. Sidebar rows use 18pt.
  static func icon(symbolName: String, tint: NSColor, dimension: CGFloat = 18) -> NSImage {
    let key = CacheKey(symbolName: symbolName, tint: tint, dimension: dimension)
    if let cached = cache[key] {
      return cached
    }

    let image = NSImage(size: NSSize(width: dimension, height: dimension), flipped: false) { rect in
      let cornerRadius = rect.width * 0.28
      let backgroundPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
      tint.setFill()
      backgroundPath.fill()

      let symbolConfig = NSImage.SymbolConfiguration(pointSize: dimension * 0.62, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
      if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfig)
      {
        let symbolSize = symbol.size
        let origin = NSPoint(
          x: rect.midX - symbolSize.width / 2,
          y: rect.midY - symbolSize.height / 2
        )
        symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
      }
      return true
    }
    image.isTemplate = false
    cache[key] = image
    return image
  }
}
