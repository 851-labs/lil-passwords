import AppKit
import LilPasswordsKit

/// A small circular countdown indicator: a ring that depletes clockwise from the top as a TOTP
/// code's remaining validity window shrinks, turning red in the code's final seconds — matching
/// the countdown ring Apple Passwords (and most authenticator apps) draw next to each code.
final class CountdownRingView: NSView {
  /// 1.0 when a code has just been generated, 0.0 the instant it's about to change.
  private var fractionRemaining: CGFloat = 1

  override var isFlipped: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    let lineWidth: CGFloat = 2
    let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
    guard rect.width > 0, rect.height > 0 else { return }

    let track = NSBezierPath(ovalIn: rect)
    track.lineWidth = lineWidth
    NSColor.tertiaryLabelColor.setStroke()
    track.stroke()

    guard fractionRemaining > 0 else { return }

    let center = NSPoint(x: rect.midX, y: rect.midY)
    let radius = rect.width / 2
    // Starts at 12 o'clock (90°) and sweeps clockwise as time elapses, so the ring reads as
    // "how much time is left" rather than "how much has passed".
    let startAngle: CGFloat = 90
    let endAngle = startAngle - 360 * fractionRemaining

    let progress = NSBezierPath()
    progress.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
    progress.lineWidth = lineWidth
    progress.lineCapStyle = .round
    (fractionRemaining < 0.2 ? NSColor.systemRed : NSColor.controlAccentColor).setStroke()
    progress.stroke()
  }

  /// Updates the ring to reflect `totp`'s remaining validity as of `now`, redrawing immediately.
  func update(totp: TOTP, at now: Date) {
    let secondsRemaining = totp.nextChange(after: now).timeIntervalSince(now)
    fractionRemaining = CGFloat(max(0, min(1, secondsRemaining / totp.period)))
    needsDisplay = true
  }
}
