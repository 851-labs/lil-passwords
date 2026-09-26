import AppKit
import Foundation
import PDFKit

extension RecoveryKitDocument {
  /// Renders the first page of PDF data produced by `renderPDF(_:)` to a PNG, `width` points
  /// wide (height follows the page's own aspect ratio). For tooling that wants to look at the
  /// generated recovery kit without opening it in an external viewer — a snapshot test, a
  /// tophat/QA script — not something the app itself needs: the app hands `renderPDF(_:)`'s raw
  /// `Data` straight to `NSSavePanel`/`PDFView`'s print operation.
  ///
  /// Returns `nil` if `pdfData` isn't a valid, non-empty PDF.
  public static func renderFirstPagePNG(from pdfData: Data, width: CGFloat = 900) -> Data? {
    guard let document = PDFDocument(data: pdfData), let page = document.page(at: 0) else { return nil }

    let pageBounds = page.bounds(for: .mediaBox)
    guard pageBounds.width > 0, pageBounds.height > 0 else { return nil }

    let scale = width / pageBounds.width
    let pixelSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)

    let thumbnail = page.thumbnail(of: pixelSize, for: .mediaBox)
    guard let tiffData = thumbnail.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiffData) else {
      return nil
    }
    return bitmap.representation(using: .png, properties: [:])
  }
}
