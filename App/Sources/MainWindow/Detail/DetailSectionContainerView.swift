import AppKit

/// A rounded, grouped box of rows with hairline dividers between them — the "User Name",
/// "Password", "Verification Code", "Websites", and "Notes" groups in Apple Passwords' detail
/// pane are all one of these, just with different row content.
@MainActor
final class DetailSectionContainerView: NSView {
  private let stack: NSStackView = {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.masksToBounds = true

    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    updateBackgroundColor()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateBackgroundColor()
  }

  /// Replaces every row currently shown with `rows`, inserting a hairline divider between each
  /// consecutive pair. Safe to call repeatedly (e.g. once per keystroke's worth of state
  /// change) — existing rows are torn down and rebuilt each time.
  func setRows(_ rows: [NSView]) {
    for view in stack.arrangedSubviews {
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    for (index, row) in rows.enumerated() {
      if index > 0 {
        stack.addArrangedSubview(makeDivider())
      }
      row.translatesAutoresizingMaskIntoConstraints = false
      stack.addArrangedSubview(row)
      NSLayoutConstraint.activate([
        row.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
        row.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
      ])
    }
  }

  private func updateBackgroundColor() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      self.layer?.backgroundColor = NSColor.detailGroupBackground.cgColor
    }
  }

  private func makeDivider() -> NSView {
    let divider = NSBox()
    divider.boxType = .separator
    divider.translatesAutoresizingMaskIntoConstraints = false
    divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return divider
  }
}

extension NSColor {
  /// The subtle rounded-rect group fill System Settings-style panes use behind each field
  /// group. AppKit has no built-in "system fill" equivalent to UIKit's, so this approximates it
  /// with a translucent overlay that reads correctly on both the light and dark backgrounds the
  /// detail pane can sit on.
  static var detailGroupBackground: NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor.white.withAlphaComponent(0.06)
        : NSColor.black.withAlphaComponent(0.04)
    }
  }
}
