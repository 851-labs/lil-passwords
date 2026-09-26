import AppKit
import LilPasswordsKit

/// A live, on-screen QR code, drawn the same vector-module way `RecoveryKitDocument` draws its
/// printable recovery-kit QR code (one `CGRect` fill per dark module — see that file's
/// `drawQRCode(_:in:context:)` doc comment for why this avoids embedding/scaling a raster image),
/// just via `NSView.draw(_:)` instead of into a `CGContext` PDF page.
///
/// Used by ``WiFiQRCodeSheetController`` to show a `WIFI:...;;` payload as a scannable code; not
/// specific to Wi-Fi itself, so any other feature that wants an on-screen QR code can reuse this
/// directly.
final class QRCodeView: NSView {
  private var grid: QRModuleGrid?

  override var isFlipped: Bool { false }

  /// - Returns: `false` if `string` couldn't be encoded (see ``QRModuleGrid/init(encoding:)``) —
  ///   the view draws nothing in that case rather than a stale/blank code.
  @discardableResult
  func setPayload(_ string: String) -> Bool {
    grid = QRModuleGrid(encoding: string)
    needsDisplay = true
    return grid != nil
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.white.setFill()
    bounds.fill()

    guard let grid, let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    NSColor.black.setFill()

    let moduleCount = grid.moduleCount
    let xEdges = (0...moduleCount).map { bounds.minX + bounds.width * CGFloat($0) / CGFloat(moduleCount) }
    let yEdges = (0...moduleCount).map { bounds.maxY - bounds.height * CGFloat($0) / CGFloat(moduleCount) }

    for row in 0..<moduleCount {
      for column in 0..<moduleCount where grid.isDark(row: row, column: column) {
        let rect = CGRect(
          x: xEdges[column],
          y: yEdges[row + 1],
          width: xEdges[column + 1] - xEdges[column],
          height: yEdges[row] - yEdges[row + 1]
        )
        context.fill(rect)
      }
    }
    context.restoreGState()
  }
}
