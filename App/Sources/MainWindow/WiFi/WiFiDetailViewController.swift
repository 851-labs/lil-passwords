import AppKit
import LilPasswordsKit

/// The Wi-Fi category's detail column: the selected network's name, security type, a
/// reveal-to-see password row, a "Show Network QR Code" button, and Copy — matching Apple
/// Passwords' Wi-Fi detail card. Non-editable throughout (`DetailIdentityView.configure(isEditing:
/// false)` always): unlike a saved password item, a Wi-Fi network's name/security/password all
/// come from macOS itself (see `docs/adr/0005-wifi-passwords.md`), so there's nothing here for a
/// person to type in and save back.
@MainActor
final class WiFiDetailViewController: NSViewController {
  private let viewModel: WiFiNetworkViewModel
  private var network: WiFiNetwork?

  private let emptyStateView = EmptyStateView()
  private let scrollView = NSScrollView()
  private let contentStack = NSStackView()
  private let identityView = DetailIdentityView()
  private let cardView = CardView()
  private let securityValueField = NSTextField(labelWithString: "")
  private let passwordRowView = WiFiPasswordRowView()
  private let showQRCodeButton = NSButton()

  init(viewModel: WiFiNetworkViewModel) {
    self.viewModel = viewModel
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func loadView() {
    let view = NSView()

    emptyStateView.translatesAutoresizingMaskIntoConstraints = false
    emptyStateView.configure(
      symbolName: "wifi",
      title: String(localized: "No Network Selected"),
      message: String(localized: "Select a Wi-Fi network to see its details.")
    )

    configureContentStack()

    scrollView.documentView = contentStack
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    view.addSubview(emptyStateView)
    view.addSubview(scrollView)

    NSLayoutConstraint.activate([
      emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      emptyStateView.topAnchor.constraint(equalTo: view.topAnchor),
      emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
    ])

    self.view = view
    showNoSelection()
  }

  private func configureContentStack() {
    contentStack.orientation = .vertical
    contentStack.alignment = .leading
    contentStack.spacing = 20
    contentStack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
    contentStack.translatesAutoresizingMaskIntoConstraints = false

    securityValueField.font = .systemFont(ofSize: 13)
    securityValueField.textColor = .secondaryLabelColor
    securityValueField.alignment = .right
    let securityRow = KeyValueRow(label: String(localized: "Security"), value: securityValueField)

    passwordRowView.onReveal = { [weak self] in
      guard let self, let network = self.network else {
        throw WiFiPasswordRevealError.notFound
      }
      return try await self.viewModel.revealPassword(for: network)
    }
    passwordRowView.onCopy = { password in
      Pasteboard.copySecret(password)
    }

    cardView.setContent(header: identityView, rows: [securityRow, passwordRowView])
    cardView.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

    showQRCodeButton.title = String(localized: "Show Network QR Code")
    showQRCodeButton.image = NSImage(systemSymbolName: "qrcode", accessibilityDescription: nil)
    showQRCodeButton.imagePosition = .imageLeading
    showQRCodeButton.bezelStyle = .rounded
    showQRCodeButton.controlSize = .large
    showQRCodeButton.target = self
    showQRCodeButton.action = #selector(showQRCodeTapped)
    showQRCodeButton.translatesAutoresizingMaskIntoConstraints = false

    contentStack.addArrangedSubview(cardView)
    contentStack.addArrangedSubview(showQRCodeButton)
    NSLayoutConstraint.activate([
      cardView.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor, constant: 24),
      cardView.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor, constant: -24),
      showQRCodeButton.centerXAnchor.constraint(equalTo: contentStack.centerXAnchor),
    ])
  }

  func show(network: WiFiNetwork?) {
    self.network = network
    passwordRowView.reset()

    guard let network else {
      showNoSelection()
      return
    }

    emptyStateView.isHidden = true
    scrollView.isHidden = false

    identityView.configure(title: network.ssid, icon: Self.wifiIcon(), isEditing: false)
    securityValueField.stringValue = network.security?.displayName ?? String(localized: "Unknown")
    view.setAccessibilityLabel(String(localized: "\(network.ssid), \(securityValueField.stringValue)"))
  }

  private func showNoSelection() {
    emptyStateView.isHidden = false
    scrollView.isHidden = true
    view.setAccessibilityLabel(nil)
  }

  @objc
  private func showQRCodeTapped() {
    guard let network, let window = view.window else { return }
    Task {
      // Showing the QR code always needs the password (an SSID-only, `nopass` code is only ever
      // for open networks, which don't apply here), so tapping this button triggers the same
      // admin-authentication reveal the password row's own reveal button would — mirroring Apple
      // Passwords, which likewise authenticates before showing this sheet.
      let password = try? await viewModel.revealPassword(for: network)
      guard let password else {
        NSSound.beep()
        return
      }
      WiFiQRCodeSheetController.present(
        ssid: network.ssid,
        password: password,
        security: network.security ?? .wpa2Personal,
        from: window
      )
    }
  }

  /// A colored rounded-square Wi-Fi glyph for the detail card's header — the same shape
  /// `MonogramIcon` draws for a letter, just with `SidebarCategory.wifi`'s own symbol/tint instead
  /// of a monogram letter, since a Wi-Fi network has no title to take a letter from.
  private static func wifiIcon(dimension: CGFloat = 64) -> NSImage {
    NSImage(size: NSSize(width: dimension, height: dimension), flipped: false) { rect in
      let cornerRadius = rect.width * 0.28
      let backgroundPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
      SidebarCategory.wifi.tintColor.setFill()
      backgroundPath.fill()

      let configuration = NSImage.SymbolConfiguration(pointSize: dimension * 0.5, weight: .medium)
      guard
        let symbol = NSImage(systemSymbolName: SidebarCategory.wifi.symbolName, accessibilityDescription: nil)?
          .withSymbolConfiguration(configuration)
      else { return true }
      let tinted = symbol.tinted(with: .white)
      let symbolSize = tinted.size
      let origin = NSPoint(x: rect.midX - symbolSize.width / 2, y: rect.midY - symbolSize.height / 2)
      tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
      return true
    }
  }
}

extension NSImage {
  /// Draws this (template) image tinted a solid color, for compositing onto a colored background
  /// like ``WiFiDetailViewController/wifiIcon(dimension:)``'s square — `contentTintColor` only
  /// affects an `NSImageView`'s own rendering, not a standalone `NSImage` about to be drawn
  /// directly into another image.
  fileprivate func tinted(with color: NSColor) -> NSImage {
    let image = NSImage(size: size, flipped: false) { rect in
      color.set()
      rect.fill()
      self.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
      return true
    }
    image.isTemplate = false
    return image
  }
}
