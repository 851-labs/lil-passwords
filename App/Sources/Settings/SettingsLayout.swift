import AppKit

/// Small layout helpers shared by the Settings tabs (General/Security/Agents), so each tab's view
/// controller can focus on its own controls instead of repeating Auto Layout boilerplate.
@MainActor
enum SettingsLayout {
  /// Fixed content width every tab uses, matching System Settings' fixed-width panels — the
  /// window itself resizes per tab (via `preferredContentSize`), not the content within a tab.
  static let contentWidth: CGFloat = 420
  private static let contentInset: CGFloat = 20

  /// A left-aligned, secondary-colored explanatory line, wrapped to the content width.
  static func caption(_ text: String) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: 11)
    field.textColor = .secondaryLabelColor
    field.preferredMaxLayoutWidth = contentWidth - 2 * contentInset
    return field
  }

  /// A bold section header, e.g. "Access Log".
  static func sectionHeader(_ text: String) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: 13, weight: .semibold)
    return field
  }

  /// A `NSGridView` row label, right-aligned the way System Settings labels its popups/steppers.
  static func rowLabel(_ text: String) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.alignment = .right
    return field
  }

  /// Lays out `views` top-to-bottom, pinned to ``contentWidth`` with standard window margins, and
  /// returns the container view a tab's `loadView()` should use.
  static func makeStack(_ views: [NSView], spacing: CGFloat = 16) -> NSView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = spacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.edgeInsets = NSEdgeInsets(
      top: contentInset,
      left: contentInset,
      bottom: contentInset,
      right: contentInset
    )

    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      container.widthAnchor.constraint(equalToConstant: contentWidth),
    ])
    return container
  }

  /// The size a `NSTabViewController` tab should report as `preferredContentSize`: fixed content
  /// width, height measured from the (already Auto Layout-constrained) view's fitting size.
  static func preferredSize(for view: NSView) -> NSSize {
    view.layoutSubtreeIfNeeded()
    return NSSize(width: contentWidth, height: view.fittingSize.height)
  }
}
