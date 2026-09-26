import AppKit
import LilPasswordsKit

/// The Wi-Fi category's detail column: the selected network's name, security type, a
/// reveal-to-see password row, and a "Show Network QR Code" row — matching Apple Passwords' Wi-Fi
/// detail card. Non-editable throughout (`DetailIdentityView.configure(isEditing: false)` always):
/// unlike a saved password item, a Wi-Fi network's name/security/password all come from macOS
/// itself (see `docs/adr/0006-wifi-passwords.md`), so there's nothing here for a person to type in
/// and save back.
///
/// Top-aligned under the toolbar, like `DetailViewController` (851-2444's rework to match
/// 851-2463's Apple-parity chrome — this previously centered its card vertically instead).
@MainActor
final class WiFiDetailViewController: NSViewController {
  private let viewModel: WiFiNetworkViewModel
  private var network: WiFiNetwork?

  private let emptyStateView = EmptyStateView()
  private let contentContainer = NSView()
  private let scrollView = NSScrollView()
  private let contentStack = NSStackView()
  private let identityView = DetailIdentityView()
  private let cardView = CardView()
  private let securityValueField = NSTextField(labelWithString: "")
  private let passwordRowView = WiFiPasswordRowView()

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

    configureContentContainer(in: view)

    view.addSubview(emptyStateView)
    NSLayoutConstraint.activate([
      emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      emptyStateView.topAnchor.constraint(equalTo: view.topAnchor),
      emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    self.view = view
    showNoSelection()
  }

  private func configureContentContainer(in view: NSView) {
    contentContainer.translatesAutoresizingMaskIntoConstraints = false
    contentContainer.isHidden = true
    view.addSubview(contentContainer)
    NSLayoutConstraint.activate([
      contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      // `safeAreaLayoutGuide`, not `view.topAnchor` — see `DetailViewController.configureContentContainer(in:)`'s
      // matching comment: this split item's own initializer doesn't pre-inset content below the
      // unified toolbar, so this keeps the card top-aligned just under it (851-2444 review point
      // 3) rather than scrolling its top edge up underneath the toolbar's translucent background.
      contentContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    configureContentStack()

    let flippedDocumentView = FlippedView()
    flippedDocumentView.translatesAutoresizingMaskIntoConstraints = false
    flippedDocumentView.addSubview(contentStack)
    NSLayoutConstraint.activate([
      contentStack.leadingAnchor.constraint(equalTo: flippedDocumentView.leadingAnchor),
      contentStack.trailingAnchor.constraint(equalTo: flippedDocumentView.trailingAnchor),
      contentStack.topAnchor.constraint(equalTo: flippedDocumentView.topAnchor),
      contentStack.bottomAnchor.constraint(equalTo: flippedDocumentView.bottomAnchor),
    ])
    scrollView.documentView = flippedDocumentView
    NSLayoutConstraint.activate([
      flippedDocumentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
    ])

    contentContainer.addSubview(scrollView)
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
    ])
  }

  private func configureContentStack() {
    contentStack.orientation = .vertical
    contentStack.alignment = .leading
    contentStack.spacing = 20
    // Matches `DetailViewController.documentStack`'s insets (851-2463/851-2444): a small top inset
    // (the toolbar itself already provides the visual breathing room above) with the usual 24pt on
    // the other three sides.
    contentStack.edgeInsets = NSEdgeInsets(top: 8, left: 24, bottom: 24, right: 24)
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

    // "Show Network QR Code" now lives inside the card as its own row (851-2444 review point 3),
    // rather than a separate button centered below it — its action reads `self.network` at tap
    // time (see `showQRCodeTapped()`), same as `passwordRowView.onReveal` above, so this one row
    // instance stays correct across every `show(network:)` call without being rebuilt.
    let qrCodeRow = AddRowView(
      title: String(localized: "Show Network QR Code"),
      symbolName: "qrcode",
      action: { [weak self] in self?.showQRCodeTapped() }
    )

    cardView.setContent(header: identityView, rows: [securityRow, passwordRowView, qrCodeRow])

    contentStack.addArrangedSubview(cardView)
    // Matches `DetailViewController`'s card-width pattern: the stack's own `alignment = .leading`
    // plus `edgeInsets` positions the card at the 24pt leading inset; this constant (-48) accounts
    // for both the leading and trailing insets so the card's trailing edge lines up too.
    cardView.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -48).isActive = true
  }

  func show(network: WiFiNetwork?) {
    self.network = network
    passwordRowView.reset()

    guard let network else {
      showNoSelection()
      return
    }

    emptyStateView.isHidden = true
    contentContainer.isHidden = false

    identityView.configure(title: network.ssid, icon: Self.wifiIcon(), isEditing: false)
    securityValueField.stringValue = network.security?.displayName ?? String(localized: "Unknown")
    // `setAccessibilityLabel` alone doesn't make a plain, multi-subview `NSView` an accessibility
    // element in its own right (851-2466) — without `setAccessibilityElement(true)`, VoiceOver
    // just descends straight into the card's own rows and never surfaces this summary at all, the
    // same "relying on one property alone isn't enough" gap docs/accessibility.md calls out for
    // icon-only controls.
    view.setAccessibilityElement(true)
    view.setAccessibilityLabel(String(localized: "\(network.ssid), \(securityValueField.stringValue)"))
  }

  private func showNoSelection() {
    emptyStateView.isHidden = false
    contentContainer.isHidden = true
    // Un-set the whole-view summary element too, not just its label — otherwise VoiceOver would
    // land on this view as an unlabeled group instead of skipping straight to `emptyStateView`'s
    // own "No Network Selected" text.
    view.setAccessibilityElement(false)
    view.setAccessibilityLabel(nil)
  }

  private func showQRCodeTapped() {
    guard let network, let window = view.window else { return }
    Task {
      // Showing the QR code always needs the password (an SSID-only, `nopass` code is only ever
      // for open networks, which don't apply here), so tapping this row triggers the same
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
