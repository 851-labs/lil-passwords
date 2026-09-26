import AppKit

/// A capsule-shaped cluster of borderless icon buttons with hairline dividers between them —
/// Apple Passwords groups its list column's sort and "+" controls this way (851-2463). Callers
/// own the buttons (so each can have its own target/action independently — sort targets
/// `ItemListViewController`, "+" targets `MainToolbarController` itself) and just hand them to
/// this view for layout and chrome.
@MainActor
final class CapsuleToolbarView: NSView {
  let buttons: [NSButton]

  init(buttons: [NSButton]) {
    self.buttons = buttons
    super.init(frame: .zero)
    configureSubviews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func configureSubviews() {
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 14
    layer?.masksToBounds = true
    updateBackgroundColor()

    var arranged: [NSView] = []
    for (index, button) in buttons.enumerated() {
      button.isBordered = false
      button.bezelStyle = .regularSquare
      button.imagePosition = .imageOnly
      button.contentTintColor = .labelColor
      button.translatesAutoresizingMaskIntoConstraints = false
      button.widthAnchor.constraint(equalToConstant: 32).isActive = true
      button.heightAnchor.constraint(equalToConstant: 28).isActive = true
      // Layer-backed (rather than relying on the bezel's own mouse-down highlight, which a
      // borderless `.regularSquare` button doesn't draw) so callers like `ItemListViewController`
      // can paint a pressed-looking background behind a specific button — e.g. the sort button
      // while its menu is open (851-2463).
      button.wantsLayer = true
      button.layer?.cornerRadius = 6
      if index > 0 {
        arranged.append(makeDivider())
      }
      arranged.append(button)
    }

    let stack = NSStackView(views: arranged)
    stack.orientation = .horizontal
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false

    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      heightAnchor.constraint(equalToConstant: 28),
    ])
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateBackgroundColor()
  }

  private func updateBackgroundColor() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      self.layer?.backgroundColor = NSColor.toolbarCapsuleBackground.cgColor
    }
  }

  private func makeDivider() -> NSView {
    let divider = NSBox()
    divider.boxType = .separator
    divider.translatesAutoresizingMaskIntoConstraints = false
    divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
    divider.heightAnchor.constraint(equalToConstant: 16).isActive = true
    return divider
  }
}

extension NSColor {
  /// The subtle capsule fill behind grouped toolbar controls (sort + "+"), mirroring
  /// `detailGroupBackground`'s approach (`DetailSectionContainerView.swift`) for a translucent
  /// overlay that reads correctly on both the light and dark toolbar materials.
  static var toolbarCapsuleBackground: NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor.white.withAlphaComponent(0.14)
        : NSColor.black.withAlphaComponent(0.08)
    }
  }

  /// The pressed/highlighted background painted behind a capsule button while it's "active" —
  /// e.g. the sort button for as long as its menu is open (851-2463) — noticeably darker/lighter
  /// than `toolbarCapsuleBackground` so it reads as a distinct pressed state on top of it.
  static var toolbarCapsuleButtonHighlight: NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor.white.withAlphaComponent(0.28)
        : NSColor.black.withAlphaComponent(0.18)
    }
  }
}
