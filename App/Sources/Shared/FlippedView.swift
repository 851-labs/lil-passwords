import AppKit

/// A plain flipped `NSView`, so a document view inside an `NSScrollView` lays out top-down like
/// everything else in AppKit instead of `NSScrollView`'s default bottom-up coordinate space — and,
/// just as importantly, so content shorter than the scroll view's visible area rests pinned to the
/// top rather than vertically centered.
///
/// Shared by `DetailViewController` and `WiFiDetailViewController` (851-2444's rework to match
/// 851-2463's Apple-parity chrome: a top-aligned detail card, not a centered one).
final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}
