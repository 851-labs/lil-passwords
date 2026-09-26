import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Renders the printable recovery kit PDF handed to a user right after `VaultStoring
/// .createVault()` returns their one-time `VaultCrypto.RecoveryKey` (see
/// `docs/adr/0002-crypto.md`). One page: the app name, the grouped recovery key in large
/// monospaced type, a QR code encoding the same key, the date it was generated, and plain-English
/// instructions on what the key is for and how to keep it safe.
///
/// This is a plain rendering utility, not a UI — it draws headlessly into a `CGContext` (via
/// `AppKit`'s text-layout and image-drawing primitives, used off-screen, not a window) and hands
/// back `Data`. The AppKit sheet that shows this PDF to the user and confirms they saved it lives
/// in the app target (`App/Sources/RecoveryKit`), not here, so this stays usable from a unit test
/// or any other headless context.
public enum RecoveryKitDocument {
  /// Everything the PDF needs to render. Deliberately holds only the recovery key's
  /// already-rendered `displayString`, never the raw `VaultCrypto.RecoveryKey`/its entropy — by
  /// the time this renders, the caller already holds the only copy of the key that will ever
  /// exist, and this type has no reason to touch the entropy itself.
  public struct Content: Sendable, Equatable {
    public var appName: String
    public var displayKey: String
    public var createdAt: Date

    public init(appName: String, displayKey: String, createdAt: Date = Date()) {
      self.appName = appName
      self.displayKey = displayKey
      self.createdAt = createdAt
    }
  }

  /// US Letter at 72 dpi. Printable without the caller thinking about paper size; a page this
  /// simple looks fine on A4 too once a print driver rescales it to fit.
  private static let pageSize = CGSize(width: 612, height: 792)
  private static let margin: CGFloat = 56

  /// Renders `content` as single-page PDF data. Returns empty `Data` only if `CoreGraphics`
  /// itself fails to open a PDF context, which isn't expected to happen in practice.
  public static func renderPDF(_ content: Content) -> Data {
    let mutableData = CFDataCreateMutable(nil, 0)!
    var mediaBox = CGRect(origin: .zero, size: pageSize)
    guard let consumer = CGDataConsumer(data: mutableData),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else {
      return Data()
    }

    context.beginPDFPage(nil)
    draw(content, in: context)
    context.endPDFPage()
    context.closePDF()
    return mutableData as Data
  }

  private static func draw(_ content: Content, in context: CGContext) {
    // `CGContext`'s PDF drawing origin is bottom-left, matching `NSGraphicsContext(flipped:
    // false)` — the coordinate space this whole method's top-down `cursorY` math assumes.
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

    let contentWidth = pageSize.width - margin * 2
    var cursorY = pageSize.height - margin

    cursorY = drawText(
      "\(content.appName) Recovery Kit",
      font: .boldSystemFont(ofSize: 24),
      color: .black,
      maxWidth: contentWidth,
      topLeft: CGPoint(x: margin, y: cursorY),
      alignment: .center
    )

    cursorY -= 6
    cursorY = drawText(
      "Generated \(Self.dateFormatter.string(from: content.createdAt))",
      font: .systemFont(ofSize: 12),
      color: .darkGray,
      maxWidth: contentWidth,
      topLeft: CGPoint(x: margin, y: cursorY),
      alignment: .center
    )

    cursorY -= 40
    cursorY = drawText(
      content.displayKey,
      font: .monospacedSystemFont(ofSize: 26, weight: .semibold),
      color: .black,
      maxWidth: contentWidth,
      topLeft: CGPoint(x: margin, y: cursorY),
      alignment: .center
    )

    cursorY -= 28
    if let grid = QRModuleGrid(displayKey: content.displayKey) {
      let displaySize = CGSize(width: 150, height: 150)
      let origin = CGPoint(x: (pageSize.width - displaySize.width) / 2, y: cursorY - displaySize.height)
      drawQRCode(grid, in: CGRect(origin: origin, size: displaySize), context: context)
      cursorY = origin.y - 32
    }

    cursorY = drawText(
      instructions(for: content.appName),
      font: .systemFont(ofSize: 12),
      color: .black,
      maxWidth: contentWidth,
      topLeft: CGPoint(x: margin, y: cursorY),
      alignment: .left,
      lineSpacing: 5
    )
  }

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .long
    formatter.timeStyle = .short
    return formatter
  }()

  private static func instructions(for appName: String) -> String {
    """
    This recovery key is the only way to restore your \(appName) vault on a new Mac, or if you \
    ever lose access to this Mac's Keychain (a reinstall, a new Mac, or moving to a different \
    Apple Account). Anyone who has this key and a copy of your vault file can read every \
    password in it, so treat it like a spare house key, not a note to yourself:

    •  Store this page somewhere safe, such as a fireproof safe or a locked drawer — not a photo \
    on your phone, an email to yourself, or a file in cloud storage.
    •  \(appName) shows this key exactly once, right now. There is no way to see it again later, \
    only to generate a brand-new one and retire this page.
    •  If you ever suspect someone else has seen this key, generate a new recovery key from \
    \(appName) settings as soon as you can.
    """
  }

  /// Draws `string`, top-aligned at `topLeft` and wrapped to `maxWidth`, into the current
  /// `NSGraphicsContext`. Returns the y coordinate just below what it drew, in the same
  /// bottom-left-origin space `topLeft` was given in, so callers can chain calls top-to-bottom.
  @discardableResult
  private static func drawText(
    _ string: String,
    font: NSFont,
    color: NSColor,
    maxWidth: CGFloat,
    topLeft: CGPoint,
    alignment: NSTextAlignment,
    lineSpacing: CGFloat = 0
  ) -> CGFloat {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = alignment
    paragraphStyle.lineSpacing = lineSpacing

    let attributedString = NSAttributedString(
      string: string,
      attributes: [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraphStyle,
      ]
    )

    let boundingSize = CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
    let boundingRect = attributedString.boundingRect(with: boundingSize, options: [.usesLineFragmentOrigin])
    let drawRect = CGRect(
      x: topLeft.x,
      y: topLeft.y - boundingRect.height,
      width: maxWidth,
      height: boundingRect.height
    )
    attributedString.draw(with: drawRect, options: [.usesLineFragmentOrigin])
    return drawRect.minY
  }

  /// Fills one `CGRect` per dark module directly into `context` — a vector fill per module, not
  /// an embedded raster image.
  ///
  /// The previous approach drew `CIQRCodeGenerator`'s output as a `CGImage` with
  /// `context.interpolationQuality = .none`, which is exactly what you're supposed to do to stop
  /// *a context* from resampling an image it draws — but that setting only ever controlled how
  /// *this* `CGContext` would resample the image if it needed to. Handing a `CGImage` to
  /// `CGContext.draw(_:in:)` while it's building a PDF still embeds that image as its own,
  /// independent image XObject; nothing about `interpolationQuality` reaches into how a PDF
  /// *viewer* later resamples that XObject, and `/Interpolate false` on it (the flag this project
  /// previously assumed would be set, and would be honored) is only ever a hint some renderers
  /// ignore outright — which is exactly what left `recovery-kit.pdf`'s QR looking soft. Vector
  /// rects sidestep the whole question: there's no raster image in the PDF at all for anything to
  /// resample, at any zoom level or print resolution.
  ///
  /// Module boundaries are computed directly from `rect`'s edges (`xEdges`/`yEdges` below), not
  /// accumulated by repeatedly adding one module's width to the last — so two adjacent modules'
  /// shared edge is always the exact same floating-point value on both sides, with no
  /// hairline-gap-from-rounding-drift between them.
  private static func drawQRCode(_ grid: QRModuleGrid, in rect: CGRect, context: CGContext) {
    context.saveGState()
    context.setFillColor(NSColor.black.cgColor)

    let moduleCount = grid.moduleCount
    let xEdges = (0...moduleCount).map { rect.minX + rect.width * CGFloat($0) / CGFloat(moduleCount) }
    // PDF drawing here is bottom-up (`draw(_:in:)`'s `NSGraphicsContext(flipped: false)` above),
    // so module row 0 — the grid's first output row, drawn at the *top* of the QR code — lands
    // nearest `rect.maxY`, not `rect.minY`.
    let yEdges = (0...moduleCount).map { rect.maxY - rect.height * CGFloat($0) / CGFloat(moduleCount) }

    for row in 0..<moduleCount {
      for column in 0..<moduleCount where grid.isDark(row: row, column: column) {
        context.fill(
          CGRect(
            x: xEdges[column],
            y: yEdges[row + 1],
            width: xEdges[column + 1] - xEdges[column],
            height: yEdges[row] - yEdges[row + 1]
          )
        )
      }
    }

    context.restoreGState()
  }
}

/// A one-bit "is this module dark" grid read directly from `CIQRCodeGenerator`'s raw pixel
/// output — one pixel sampled per module (including whatever quiet-zone border the generator
/// surrounds the code with), at 1:1 scale, so there's no resampling for this step to get wrong
/// either.
///
/// Public (unlike the rest of this file, which is a headless PDF-rendering detail): the Wi-Fi
/// category's on-screen QR sheet (`App/Sources/MainWindow/WiFi/QRCodeView.swift`) reuses this same
/// vector-module grid to draw a live `WIFI:...` QR code, for the same reason this file avoids
/// embedding a raster image in the recovery-kit PDF — see ``drawQRCode(_:in:context:)``'s doc
/// comment.
public struct QRModuleGrid {
  public let moduleCount: Int
  private let isDarkFlags: [Bool]

  /// - Returns: `nil` if `CIQRCodeGenerator`/`CIContext` can't produce an image for `string` at
  ///   all (not expected in practice for the short ASCII strings this app ever encodes).
  init?(displayKey string: String) {
    self.init(encoding: string)
  }

  /// Same as ``init(displayKey:)``, under the name that makes sense for callers encoding
  /// something other than a recovery key (e.g. a `WIFI:...;;` payload).
  public init?(encoding string: String) {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let outputImage = filter.outputImage else { return nil }

    let extent = outputImage.extent
    let moduleCount = Int(extent.width.rounded())
    guard moduleCount > 0, Int(extent.height.rounded()) == moduleCount else { return nil }

    // Pinned to an explicit 8-bit-per-component RGBA format and a plain device RGB color space —
    // this reads raw bytes directly below, so the pixel layout needs to be exactly known rather
    // than whatever `CIContext`'s own default output format happens to be (which varies by OS
    // version, e.g. an extended-range float format on newer releases).
    let bytesPerPixel = 4
    guard
      let cgImage = CIContext().createCGImage(
        outputImage,
        from: extent,
        format: .RGBA8,
        colorSpace: CGColorSpaceCreateDeviceRGB()
      ),
      let data = cgImage.dataProvider?.data,
      let bytes = CFDataGetBytePtr(data)
    else { return nil }

    let bytesPerRow = cgImage.bytesPerRow
    var flags: [Bool] = []
    flags.reserveCapacity(moduleCount * moduleCount)
    for row in 0..<moduleCount {
      for column in 0..<moduleCount {
        let offset = row * bytesPerRow + column * bytesPerPixel
        // `CIQRCodeGenerator` renders pure black modules on a pure white background, so
        // thresholding the red channel alone is enough to tell them apart.
        flags.append(bytes[offset] < 128)
      }
    }

    self.moduleCount = moduleCount
    self.isDarkFlags = flags
  }

  public func isDark(row: Int, column: Int) -> Bool {
    isDarkFlags[row * moduleCount + column]
  }
}
