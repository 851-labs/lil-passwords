import AppKit
import LilPasswordsKit

/// Presents the "Show Network QR Code" sheet: a live `WIFI:...;;` QR code (see
/// `WiFiQRCodePayload`) another Apple device's Camera app can scan to join the same network
/// without anyone reading the password aloud or typing it in — matching Apple Passwords' own
/// Wi-Fi QR sheet. Follows the same one-window, static-`present` pattern as
/// `AddVerificationCodeSheetController`.
@MainActor
final class WiFiQRCodeSheetController: NSWindowController {
  private var completion: (() -> Void)?
  private var didFinish = false

  private init() {
    let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    window.title = String(localized: "Wi-Fi QR Code")
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Presents the sheet over `parentWindow`. `password` is only ever held in memory for exactly as
  /// long as this sheet is on screen — nothing here writes it anywhere. `completion` fires exactly
  /// once, when the sheet is dismissed.
  static func present(
    ssid: String,
    password: String?,
    security: WiFiNetworkSecurity,
    from parentWindow: NSWindow,
    completion: @escaping () -> Void = {}
  ) {
    let controller = WiFiQRCodeSheetController()
    controller.completion = completion
    guard let sheetWindow = controller.window else {
      completion()
      return
    }
    controller.showContent(ssid: ssid, password: password, security: security)
    // The sheet's completion handler is the only strong reference keeping `controller` (and
    // therefore its window) alive; `beginSheet` retains this closure for the sheet's lifetime.
    parentWindow.beginSheet(sheetWindow) { _ in
      withExtendedLifetime(controller) {}
    }
  }

  private func showContent(ssid: String, password: String?, security: WiFiNetworkSecurity) {
    let titleField = NSTextField(labelWithString: String(localized: "Scan to Join “\(ssid)”"))
    titleField.font = .boldSystemFont(ofSize: 15)
    titleField.alignment = .center
    titleField.lineBreakMode = .byTruncatingTail

    let subtitleField = NSTextField(
      wrappingLabelWithString: String(
        localized: "Scan this code with the Camera app on another Apple device to join this Wi-Fi network."
      )
    )
    subtitleField.font = .systemFont(ofSize: 12)
    subtitleField.textColor = .secondaryLabelColor
    subtitleField.alignment = .center

    let qrCodeView = QRCodeView()
    qrCodeView.wantsLayer = true
    qrCodeView.layer?.cornerRadius = 12
    qrCodeView.layer?.masksToBounds = true
    let payload = WiFiQRCodePayload.payload(ssid: ssid, password: password, security: security)
    qrCodeView.setPayload(payload)
    qrCodeView.setAccessibilityElement(true)
    qrCodeView.setAccessibilityLabel(String(localized: "QR code to join “\(ssid)”"))
    qrCodeView.translatesAutoresizingMaskIntoConstraints = false

    let doneButton = NSButton(title: String(localized: "Done"), target: self, action: #selector(doneTapped))
    doneButton.keyEquivalent = "\r"
    // `keyEquivalent = "\r"` alone doesn't reliably paint this blue in a custom sheet (851-2426
    // tophat visual audit) — same fix as `ImportPreviewViewController.importButton`.
    doneButton.bezelColor = .controlAccentColor

    let stack = NSStackView(views: [titleField, subtitleField, qrCodeView, doneButton])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 16
    stack.setCustomSpacing(20, after: subtitleField)
    stack.setCustomSpacing(24, after: qrCodeView)
    stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
    stack.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      titleField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
      subtitleField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
      qrCodeView.widthAnchor.constraint(equalToConstant: 220),
      qrCodeView.heightAnchor.constraint(equalToConstant: 220),
    ])

    window?.contentView = container
    window?.setContentSize(NSSize(width: 340, height: 420))
  }

  @objc
  private func doneTapped() {
    finish()
  }

  private func finish() {
    guard let window, !didFinish else { return }
    didFinish = true
    if let sheetParent = window.sheetParent {
      sheetParent.endSheet(window)
    } else {
      window.close()
    }
    completion?()
  }
}
