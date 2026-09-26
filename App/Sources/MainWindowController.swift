import AppKit
import LilPasswordsKit

/// Placeholder window. The three-column layout arrives in 851-2412.
@MainActor
final class MainWindowController: NSWindowController {
  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = LilPasswordsKit.productName
    window.setFrameAutosaveName("MainWindow")
    window.center()

    let label = NSTextField(labelWithString: LilPasswordsKit.productName)
    label.font = .systemFont(ofSize: 28, weight: .semibold)
    label.textColor = .secondaryLabelColor
    label.translatesAutoresizingMaskIntoConstraints = false

    let content = NSView()
    content.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
    ])
    window.contentView = content

    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }
}
