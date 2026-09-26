import AppKit

/// The small circular countdown next to a live verification code: a ring that depletes
/// clockwise from 12 o'clock as the current TOTP period elapses, matching Apple Passwords.
@MainActor
final class CountdownRingView: NSView {
  /// 0 = period just started (full ring), 1 = period about to roll over (empty ring).
  var fraction: Double = 0 {
    didSet { needsDisplay = true }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override var isFlipped: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    let lineWidth: CGFloat = 2
    let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
    let center = NSPoint(x: rect.midX, y: rect.midY)
    let radius = min(rect.width, rect.height) / 2

    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = lineWidth
    NSColor.quaternaryLabelColor.setStroke()
    track.stroke()

    let remaining = max(0, 1 - fraction)
    guard remaining > 0 else { return }

    // Start at 12 o'clock (90°) and sweep clockwise (decreasing angle) as time remains.
    let startAngle: CGFloat = 90
    let endAngle = startAngle - CGFloat(remaining) * 360

    let progress = NSBezierPath()
    progress.appendArc(withCenter: center, radius: radius, startAngle: endAngle, endAngle: startAngle)
    progress.lineWidth = lineWidth
    progress.lineCapStyle = .round
    (remaining < 0.2 ? NSColor.systemOrange : NSColor.controlAccentColor).setStroke()
    progress.stroke()
  }
}
