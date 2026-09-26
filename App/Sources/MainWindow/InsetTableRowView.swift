import AppKit

/// A row view that draws its own rounded, inset selection highlight — matching the sidebar's
/// `.sourceList` look — since `NSTableView.Style.inset` doesn't produce that shape by itself for a
/// plain single-column table view (see `ItemListViewController.configureTableView()` for why).
///
/// Shared by `ItemListViewController` and `WiFiListViewController` (851-2444's rework to match
/// 851-2463's Apple-parity chrome) — both need the exact same selection metrics, so this lives in
/// its own file rather than being duplicated or left `private` to one view controller's file.
final class InsetTableRowView: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    guard selectionHighlightStyle != .none else { return }
    // At a 56pt row height, a small fixed radius with almost no vertical inset (as this originally
    // shipped: dy: 1, radius 6) reads as a barely-softened square at a glance — the 851-2463
    // review's "square gray block" callout — since the sidebar's own `.sourceList` selection is
    // short enough (~28pt rows) that a similar radius already looks like a full pill. Matching that
    // *look* here means insetting on all four sides enough to visibly float the highlight off the
    // row's edges, with a radius large enough to read as clearly rounded rather than just
    // corner-nicked, instead of matching the sidebar's exact numbers.
    let insetRect = bounds.insetBy(dx: 8, dy: 4)
    let path = NSBezierPath(roundedRect: insetRect, xRadius: 10, yRadius: 10)
    (isEmphasized ? NSColor.controlAccentColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
    path.fill()
  }
}
