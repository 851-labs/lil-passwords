#!/usr/bin/env swift
//
// generate_icon.swift — renders the "lil passwords" macOS AppIcon set from scratch with
// CoreGraphics, so the icon is fully reproducible from source (851-2426) rather than a binary
// blob someone edited by hand in a design tool.
//
// Design brief (851-2426): in the spirit of Apple's own Passwords icon (a rounded-rect glyph on
// the macOS icon grid, with a drop shadow) but clearly distinct — Apple draws three flat colored
// keys fanned out on a near-black square; this draws a single big, rounded, "lil" friendly key
// tilted across a vivid violet → pink → orange gradient square, with a soft cast shadow under the
// key for depth and a subtle gloss highlight in the upper-left, matching how Apple's own Big
// Sur-style icons are shaded.
//
// Usage: `swift scripts/icon/generate_icon.swift` from the repo root (or anywhere — the output
// path below is resolved relative to this script's own location, not the caller's cwd). Re-run
// after changing anything in this file to regenerate every PNG in
// App/Resources/Assets.xcassets/AppIcon.appiconset. Run `make project` afterwards if the set of
// files changed (it doesn't here — the filenames are fixed) so Xcode picks up new content.
//
// Deliberately zero dependencies beyond CoreGraphics/ImageIO — no design-tool export step, no
// checked-in intermediate vector file. The entire icon is defined by the constants and drawing
// code below.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Output

/// Every image the macOS "AppIcon" asset-catalog icon set expects, as (filename, pixel size).
/// Sizes per Apple's Human Interface Guidelines icon set for macOS (16/32/128/256/512 pt at 1x
/// and 2x — 2x of 512 is the 1024 "master" size Apple's own docs render from).
let outputs: [(name: String, pixels: Int)] = [
  ("icon_16x16.png", 16),
  ("icon_16x16@2x.png", 32),
  ("icon_32x32.png", 32),
  ("icon_32x32@2x.png", 64),
  ("icon_128x128.png", 128),
  ("icon_128x128@2x.png", 256),
  ("icon_256x256.png", 256),
  ("icon_256x256@2x.png", 512),
  ("icon_512x512.png", 512),
  ("icon_512x512@2x.png", 1024),
]

let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let appIconSetURL =
  repoRoot
  .appendingPathComponent("App/Resources/Assets.xcassets/AppIcon.appiconset")

// MARK: - Design space

// Every shape below is defined in a fixed 1024×1024 design space; each requested pixel size is
// rendered by scaling the CTM, not by rastering once and downsampling, so every size stays crisp
// (no resampling blur at 16pt).
let canvas: CGFloat = 1024

// Apple's macOS Big Sur+ icon grid: the squircle occupies a centered square noticeably inset from
// the full 1024 canvas (the system, and Finder/Dock, add their own drop shadow relative to this
// shape's true edges — leaving the margin is what makes icons line up with Apple's own in the
// Dock). ~824pt square, corner radius ~22.5% of its side, matching Apple's published template.
let squircleSide: CGFloat = 824
let squircleRadius: CGFloat = 185
let squircleOrigin = CGPoint(x: (canvas - squircleSide) / 2, y: (canvas - squircleSide) / 2)
let squircleRect = CGRect(origin: squircleOrigin, size: CGSize(width: squircleSide, height: squircleSide))

// MARK: - Color

extension CGColor {
  static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
  }
}

enum Palette {
  // Vivid, warm gradient — violet through hot pink to orange. Chosen specifically to read as
  // nothing like Apple's own near-black Passwords icon at a glance, in both light and dark
  // desktop backgrounds (see the lock-screen reference screenshots this ticket shipped with).
  static let gradientTopLeft = CGColor.rgb(124, 58, 237) // #7C3AED violet
  static let gradientMid = CGColor.rgb(236, 64, 122) // #EC407A pink
  static let gradientBottomRight = CGColor.rgb(251, 146, 60) // #FB923C orange

  static let keyFillTop = CGColor.rgb(255, 255, 255)
  static let keyFillBottom = CGColor.rgb(255, 244, 230) // faint warm cream, catches the orange below
  static let keyShadow = CGColor.rgb(40, 12, 30, 0.34)
  static let glossHighlight = CGColor.rgb(255, 255, 255, 0.20)
}

// MARK: - Drawing

func addSquirclePath(to context: CGContext, rect: CGRect, radius: CGFloat) {
  context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
}

/// The background: the squircle filled with a diagonal 3-stop gradient, plus a soft radial gloss
/// highlight near the top-left, the way Apple's own system icons fake a glossy, lit-from-above
/// surface without a literal specular render.
func drawBackground(in context: CGContext) {
  context.saveGState()
  addSquirclePath(to: context, rect: squircleRect, radius: squircleRadius)
  context.clip()

  let colors = [Palette.gradientTopLeft, Palette.gradientMid, Palette.gradientBottomRight] as CFArray
  guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])
  else { fatalError("Failed to build background gradient") }
  context.drawLinearGradient(
    gradient,
    start: CGPoint(x: squircleRect.minX, y: squircleRect.maxY),
    end: CGPoint(x: squircleRect.maxX, y: squircleRect.minY),
    options: []
  )

  // Gloss: a soft white radial highlight, centered in the upper-left third, faded to fully
  // transparent well before the edges.
  guard
    let gloss = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(),
      colors: [Palette.glossHighlight, CGColor.rgb(255, 255, 255, 0)] as CFArray,
      locations: [0, 1]
    )
  else { fatalError("Failed to build gloss gradient") }
  let glossCenter = CGPoint(x: squircleRect.minX + squircleSide * 0.32, y: squircleRect.maxY - squircleSide * 0.28)
  context.drawRadialGradient(
    gloss,
    startCenter: glossCenter, startRadius: 0,
    endCenter: glossCenter, endRadius: squircleSide * 0.62,
    options: []
  )

  context.restoreGState()
}

// Bow (the ring part you'd loop a keyring through) dimensions — shared between `addBowPath` and
// `addShaftAndTeethPath` since the shaft's overlap into the bow is measured relative to both.
let bowRadius: CGFloat = 128
let bowThickness: CGFloat = 62

/// The bow: a ring, drawn as two independent closed circle subpaths (outer, then inner) and left
/// to the even-odd fill rule to punch the inner one out as a hole. Built with `CGPath(ellipseIn:)`
/// rather than `addArc(startAngle:endAngle:)` — two consecutive `addArc` full-sweep calls on one
/// `CGMutablePath` don't start a new subpath between them, so they get bridged into a single
/// connected outline instead of staying two separate closed loops, and even-odd can't punch a hole
/// out of that (found by rendering this and seeing a solid disc where the ring should be — see git
/// history). `addPath` of a whole separate `CGPath` always starts a fresh subpath, avoiding the
/// bridge entirely.
///
/// Deliberately kept as its own path, filled in its own `fillPath`/`clip` call, rather than
/// combined with `addShaftAndTeethPath`'s shapes into one path filled once — see that function's
/// doc comment for why mixing them broke the even-odd hole punch (851-2426 review: a visible seam
/// where the shaft met the ring).
func addBowPath(to path: CGMutablePath) {
  let bowInnerRadius = bowRadius - bowThickness
  path.addPath(CGPath(ellipseIn: CGRect(x: -bowRadius, y: -bowRadius, width: bowRadius * 2, height: bowRadius * 2), transform: nil))
  path.addPath(
    CGPath(
      ellipseIn: CGRect(x: -bowInnerRadius, y: -bowInnerRadius, width: bowInnerRadius * 2, height: bowInnerRadius * 2),
      transform: nil))
}

/// The shaft and both teeth, drawn in the same local coordinate space as `addBowPath` (bow
/// centered at the origin, shaft running in +y — "down" once flipped/rotated into place in
/// `drawKey`). None of these three shapes has a hole, so — unlike the bow — there's no even-odd
/// hazard filling this path on its own with any fill rule.
///
/// This used to be appended onto the *same* `CGMutablePath` as `addBowPath`'s two circles, filled
/// in one combined even-odd `fillPath` call. That broke wherever the shaft's rect overlapped the
/// bow's solid annulus (deliberate, by design — `shaftTop` starts inside the bow's radius so the
/// two pieces read as one continuous shape): even-odd counts fill parity across *every* subpath in
/// the call, so a point inside both the ring's filled annulus (parity 1) and the shaft (parity 2)
/// came out even, i.e. unfilled — punching an unwanted second hole exactly at the join, which is
/// the seam/gap the 851-2426 review caught. Splitting the bow and the shaft+teeth into two
/// independent paths, each filled/clipped in its own call (see `drawKey`), fixes this: every pixel
/// where they overlap just gets the same opaque color painted twice, which looks identical to one
/// continuous shape.
func addShaftAndTeethPath(to path: CGMutablePath) {
  // Shaft: a rounded bar from the bottom of the bow straight down. Starts inside the bow's own
  // radius on purpose, so the two pieces overlap and read as one shape.
  let shaftWidth: CGFloat = 74
  let shaftTop: CGFloat = bowRadius - bowThickness * 0.35
  let shaftBottom: CGFloat = 300
  let shaftRect = CGRect(
    x: -shaftWidth / 2, y: shaftTop, width: shaftWidth, height: shaftBottom - shaftTop)
  path.addPath(CGPath(roundedRect: shaftRect, cornerWidth: shaftWidth / 2, cornerHeight: shaftWidth / 2, transform: nil))

  // Two stubby, fully-rounded teeth near the tip, sized to still read as "key" once scaled down to
  // a 16–32px menu-bar icon — the original 56×40 teeth (851-2426 first pass) were too thin to
  // register at that size, so these are noticeably bigger and reach further past the shaft's edge.
  let toothWidth: CGFloat = 76
  let toothHeight: CGFloat = 48
  for toothTop in [CGFloat(190), CGFloat(252)] {
    let toothRect = CGRect(
      x: shaftWidth / 2 - 4, y: toothTop, width: toothWidth, height: toothHeight)
    path.addPath(
      CGPath(roundedRect: toothRect, cornerWidth: toothHeight / 2, cornerHeight: toothHeight / 2, transform: nil))
  }
}

func drawKey(in context: CGContext) {
  context.saveGState()

  // Center the key assembly slightly above true center (optically balances the extra visual
  // weight of the teeth hanging below), then tilt it — matching the jaunty, "in motion" angle
  // Apple tilts its own three keys at, but with a single silhouette instead of three.
  context.translateBy(x: canvas / 2, y: canvas / 2 + 26)
  context.rotate(by: -28 * .pi / 180)

  let bowPath = CGMutablePath()
  addBowPath(to: bowPath)
  let shaftPath = CGMutablePath()
  addShaftAndTeethPath(to: shaftPath)

  // Base fill + cast shadow, both pieces painted inside one transparency layer: CoreGraphics
  // derives the drop shadow from the layer's *flattened* alpha once it's closed, i.e. from the
  // union of the bow and the shaft+teeth together, rather than from each `fillPath` call
  // individually. That matters here — two separate opaque fills each with their own `setShadow`
  // active would each cast their own shadow, and where the shaft overlaps the bow those two
  // shadows would stack (same offset/blur, so same place) into a visibly darker smudge right at
  // the join: the same seam problem this whole split was meant to fix, just moved into the
  // shadow instead of the fill. One layer, one shadow, no double-up.
  context.saveGState()
  context.setShadow(offset: CGSize(width: 10, height: -16), blur: 20, color: Palette.keyShadow)
  context.beginTransparencyLayer(auxiliaryInfo: nil)
  context.setFillColor(Palette.keyFillTop)
  context.addPath(bowPath)
  context.fillPath(using: .evenOdd)
  context.addPath(shaftPath)
  context.fillPath(using: .winding)
  context.endTransparencyLayer()
  context.restoreGState()

  // A subtle top-to-bottom gradient glaze over the same silhouette (bright white at the bow,
  // warming slightly toward the tip) so the key doesn't read as flat — same "quiet gradient fill"
  // language the background uses. Shadow is already baked in above, so no shadow state here.
  // Clipped and painted per-piece (not via one combined even-odd clip, for the same reason the
  // fill above is split) — painting the same, fully opaque gradient twice into the overlap is
  // visually identical to once, so this is safe.
  guard
    let keyGradient = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(),
      colors: [Palette.keyFillTop, Palette.keyFillBottom] as CFArray,
      locations: [0, 1]
    )
  else { fatalError("Failed to build key gradient") }
  for (piece, rule) in [(bowPath, CGPathFillRule.evenOdd), (shaftPath, CGPathFillRule.winding)] {
    context.saveGState()
    context.addPath(piece)
    context.clip(using: rule)
    context.drawLinearGradient(
      keyGradient,
      start: CGPoint(x: 0, y: -160),
      end: CGPoint(x: 0, y: 300),
      options: []
    )
    context.restoreGState()
  }
}

func drawIcon(in context: CGContext, pixelSize: Int) {
  let scale = CGFloat(pixelSize) / canvas
  context.scaleBy(x: scale, y: scale)
  drawBackground(in: context)
  drawKey(in: context)
}

// MARK: - Rendering

func renderPNG(pixelSize: Int) -> CGImage {
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  guard
    let context = CGContext(
      data: nil,
      width: pixelSize,
      height: pixelSize,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  else { fatalError("Failed to create bitmap context at \(pixelSize)px") }
  context.interpolationQuality = .high
  drawIcon(in: context, pixelSize: pixelSize)
  guard let image = context.makeImage() else { fatalError("Failed to render image at \(pixelSize)px") }
  return image
}

func writePNG(_ image: CGImage, to url: URL) {
  guard
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { fatalError("Failed to create PNG destination at \(url.path)") }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { fatalError("Failed to write PNG at \(url.path)") }
}

try FileManager.default.createDirectory(at: appIconSetURL, withIntermediateDirectories: true)

for output in outputs {
  let image = renderPNG(pixelSize: output.pixels)
  let url = appIconSetURL.appendingPathComponent(output.name)
  writePNG(image, to: url)
  print("Wrote \(output.name) (\(output.pixels)×\(output.pixels))")
}

// MARK: - Contents.json

// Written here (rather than checked in separately) so the asset catalog's manifest can never
// drift out of sync with `outputs` above — add/remove/rename an entry there and this regenerates
// to match automatically.
struct AppIconImage: Encodable {
  let size: String
  let idiom = "mac"
  let filename: String
  let scale: String
}

struct AppIconContents: Encodable {
  struct Info: Encodable {
    let version = 1
    let author = "xcode"
  }
  let images: [AppIconImage]
  let info = Info()
}

func pointSize(forPixels pixels: Int, scale: Int) -> String {
  let points = pixels / scale
  return "\(points)x\(points)"
}

let images = outputs.map { output -> AppIconImage in
  let scale = output.name.contains("@2x") ? 2 : 1
  return AppIconImage(
    size: pointSize(forPixels: output.pixels, scale: scale),
    filename: output.name,
    scale: "\(scale)x"
  )
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let contentsData = try encoder.encode(AppIconContents(images: images))
try contentsData.write(to: appIconSetURL.appendingPathComponent("Contents.json"))
print("Wrote Contents.json")
