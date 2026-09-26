import AppKit

/// The small "Copied" bubble shown after a click-to-copy field, matching the confirmation Apple
/// Passwords shows next to a field you just copied.
@MainActor
enum CopyHUD {
  /// Shows a transient "Copied" HUD anchored to `rect` within `view`. Closes itself; callers
  /// don't need to hold on to anything.
  static func show(relativeTo rect: NSRect, of view: NSView, message: String = "Copied") {
    let popover = NSPopover()
    popover.behavior = .transient
    popover.animates = true
    popover.contentViewController = HUDViewController(message: message)
    popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
      popover.performClose(nil)
    }
  }

  private final class HUDViewController: NSViewController {
    private let message: String

    init(message: String) {
      self.message = message
      super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override func loadView() {
      let checkmark = NSImageView(
        image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
      checkmark.contentTintColor = .systemGreen
      checkmark.translatesAutoresizingMaskIntoConstraints = false

      let label = NSTextField(labelWithString: message)
      label.font = .systemFont(ofSize: 12, weight: .medium)
      label.translatesAutoresizingMaskIntoConstraints = false

      let stack = NSStackView(views: [checkmark, label])
      stack.orientation = .horizontal
      stack.spacing = 6
      stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 12)
      stack.translatesAutoresizingMaskIntoConstraints = false

      let container = NSView()
      container.addSubview(stack)
      NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        stack.topAnchor.constraint(equalTo: container.topAnchor),
        stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        checkmark.widthAnchor.constraint(equalToConstant: 16),
        checkmark.heightAnchor.constraint(equalToConstant: 16),
      ])
      view = container
    }
  }
}
