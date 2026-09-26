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
}
