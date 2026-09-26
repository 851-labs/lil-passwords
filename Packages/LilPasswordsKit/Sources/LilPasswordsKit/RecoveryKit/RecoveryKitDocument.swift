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
    if let qrImage = qrCodeImage(for: content.displayKey) {
      let displaySize = CGSize(width: 150, height: 150)
      let origin = CGPoint(x: (pageSize.width - displaySize.width) / 2, y: cursorY - displaySize.height)
      // QR codes must stay crisp, sharp-edged squares to stay scannable — the default
      // interpolation would blur module edges together at this scale-up.
      let previousInterpolation = context.interpolationQuality
      context.interpolationQuality = .none
      qrImage.draw(in: CGRect(origin: origin, size: displaySize))
      context.interpolationQuality = previousInterpolation
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
    \(appName)'s settings as soon as you can.
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

  /// Renders `string` as a QR code image, one point per module (typically ~25x25pt for a key
  /// this long) — deliberately not pre-scaled, so the caller draws it with nearest-neighbor
  /// interpolation to keep module edges sharp instead of blurring them together.
  private static func qrCodeImage(for string: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let outputImage = filter.outputImage, outputImage.extent.width > 0 else { return nil }
    guard let cgImage = CIContext().createCGImage(outputImage, from: outputImage.extent) else { return nil }
    return NSImage(cgImage: cgImage, size: outputImage.extent.size)
  }
}
