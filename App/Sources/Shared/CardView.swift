import AppKit

/// A rounded, grouped card of hairline-divided rows — Apple Passwords' style for the New
/// Password sheet's single card (851-2416): an optional centered header (icon + title) at the
/// top, then label/value rows below, each separated from its neighbor by a 1pt divider.
///
/// Deliberately generic (no New-Password-specific content lives here) so 851-2463's detail-pane
/// layout work can reuse this exact card for its own grouped rows rather than growing a second,
/// slightly-different implementation alongside `DetailSectionContainerView`.
@MainActor
final class CardView: NSView {
  private let stack: NSStackView = {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()

  init(cornerRadius: CGFloat = 14) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = cornerRadius
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

  /// Replaces the card's whole content: `header` (if given, e.g. an icon + title stack) shown
  /// first, then `rows` — a hairline divider is inserted between every consecutive pair,
  /// including between `header` and the first row. Safe to call repeatedly; existing content is
  /// torn down and rebuilt each time.
  func setContent(header: NSView? = nil, rows: [NSView]) {
    for view in stack.arrangedSubviews {
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    var content = rows
    if let header {
      content.insert(header, at: 0)
    }

    for (index, view) in content.enumerated() {
      if index > 0 {
        let divider = makeDivider()
        stack.addArrangedSubview(divider)
        // Without its own leading/trailing constraints, this collapses to the tiny centered dot
        // `NSBox.separator`'s intrinsic content size actually is: a vertical `NSStackView`'s
        // default `alignment` is `.centerX`, and unlike every other arranged view below, the
        // divider had nothing overriding that to make it stretch full-width instead. Inset by
        // 16pt to line up with each row's own label/value inset, matching Apple's own row
        // dividers, which stop short of the card's rounded corners rather than running edge to
        // edge (that's reserved for the footer divider above Cancel/Save).
        NSLayoutConstraint.activate([
          divider.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16),
          divider.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
        ])
      }
      view.translatesAutoresizingMaskIntoConstraints = false
      stack.addArrangedSubview(view)
      NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
      ])
    }
  }

  private func updateBackgroundColor() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      self.layer?.backgroundColor = NSColor.cardBackground.cgColor
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
  /// The subtle rounded-rect fill a ``CardView`` sits on, just barely lighter than the sheet
  /// background behind it — matching how understated Apple Passwords' own card fill is in both
  /// appearances. AppKit has no built-in "card fill" equivalent to UIKit's, so this approximates
  /// it with a translucent overlay.
  static var cardBackground: NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor.white.withAlphaComponent(0.06)
        : NSColor.black.withAlphaComponent(0.04)
    }
  }
}
