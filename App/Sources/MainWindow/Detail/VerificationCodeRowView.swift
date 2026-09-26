import AppKit
import LilPasswordsKit

/// The read-mode "Verification Code" row: the live TOTP code with a circular countdown ring
/// that depletes each second, or a "Set Up Verification Code…" affordance when the item has no
/// `totp`.
@MainActor
final class VerificationCodeRowView: NSView {
  var onCopy: ((String) -> Void)?
  var onSetUp: (() -> Void)?

  private let ring = CountdownRingView()
  private let codeField = NSTextField(labelWithString: "")
  private let setUpButton = NSButton(title: "Set Up Verification Code…", target: nil, action: nil)
  private let copyButton = NSButton(
    image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy") ?? NSImage(),
    target: nil,
    action: nil
  )

  private var totp: TOTP?
  // `nonisolated(unsafe)` so `deinit` (which runs non-isolated) can invalidate the timer without
  // hopping back to the main actor; `Timer.invalidate()` is documented as callable from any
  // thread, so this doesn't introduce an actual race.
  private nonisolated(unsafe) var timer: Timer?
  private var trackingArea: NSTrackingArea?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureSubviews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func configureSubviews() {
    translatesAutoresizingMaskIntoConstraints = false

    ring.translatesAutoresizingMaskIntoConstraints = false

    codeField.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
    codeField.translatesAutoresizingMaskIntoConstraints = false

    setUpButton.bezelStyle = .inline
    setUpButton.isBordered = false
    setUpButton.contentTintColor = .controlAccentColor
    setUpButton.target = self
    setUpButton.action = #selector(setUpTapped)
    setUpButton.translatesAutoresizingMaskIntoConstraints = false

    copyButton.isBordered = false
    copyButton.bezelStyle = .inline
    copyButton.contentTintColor = .secondaryLabelColor
    copyButton.isHidden = true
    copyButton.toolTip = "Copy"
    copyButton.target = self
    copyButton.action = #selector(copyTapped)
    copyButton.translatesAutoresizingMaskIntoConstraints = false

    addSubview(ring)
    addSubview(codeField)
    addSubview(setUpButton)
    addSubview(copyButton)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 36),

      ring.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      ring.centerYAnchor.constraint(equalTo: centerYAnchor),
      ring.widthAnchor.constraint(equalToConstant: 16),
      ring.heightAnchor.constraint(equalToConstant: 16),

      codeField.leadingAnchor.constraint(equalTo: ring.trailingAnchor, constant: 8),
      codeField.centerYAnchor.constraint(equalTo: centerYAnchor),

      setUpButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      setUpButton.centerYAnchor.constraint(equalTo: centerYAnchor),

      copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      copyButton.widthAnchor.constraint(equalToConstant: 22),
      copyButton.heightAnchor.constraint(equalToConstant: 22),
    ])

    let click = NSClickGestureRecognizer(target: self, action: #selector(copyTapped))
    codeField.addGestureRecognizer(click)
  }

  /// - Parameter totp: The item's parsed TOTP generator, or `nil` to show the "Set Up…" state.
  func configure(totp: TOTP?) {
    self.totp = totp
    let hasCode = totp != nil
    ring.isHidden = !hasCode
    codeField.isHidden = !hasCode
    copyButton.isHidden = true
    setUpButton.isHidden = hasCode

    timer?.invalidate()
    timer = nil

    guard let totp else { return }
    tick(totp: totp)
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.tick(totp: totp)
      }
    }
    if let timer {
      RunLoop.main.add(timer, forMode: .common)
    }
  }

  private func tick(totp: TOTP) {
    let now = Date()
    codeField.stringValue = totp.code(at: now)
    let elapsed = now.timeIntervalSince1970.truncatingRemainder(dividingBy: totp.period)
    ring.fraction = elapsed / totp.period
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    copyButton.isHidden = totp == nil
  }

  override func mouseExited(with event: NSEvent) {
    copyButton.isHidden = true
  }

  @objc
  private func copyTapped() {
    guard let totp else { return }
    let code = totp.code(at: Date())
    onCopy?(code)
    CopyHUD.show(relativeTo: bounds, of: self)
  }

  @objc
  private func setUpTapped() {
    onSetUp?()
  }

  deinit {
    timer?.invalidate()
  }
}
