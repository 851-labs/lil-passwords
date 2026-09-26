import AppKit

/// A clickable label-left/value-right row inside the popover's item-detail card (851-2425),
/// following orchestrator design review of the first cut (stacked "Copy …" buttons).
///
/// Reuses the main window's own card chrome and copy affordances directly — `DetailSectionContainerView`
/// for the rounded card (`MenuBarItemDetailViewController`), `CountdownRingView` for the live TOTP
/// ring, and `CopyHUD` for the "Copied" confirmation — rather than duplicating them, since all three
/// already live in the same app target (`App/Sources/MainWindow/Detail/`) and are generic enough to
/// use as-is. This row itself is deliberately its own small type instead of a shared `KeyValueRow`:
/// the main window's `DetailValueRowView` reveals a value on hover with a separate copy button, but
/// Apple's own menu bar extra instead puts every secret behind a single click on the *whole* row —
/// nothing is ever shown "at rest" that isn't already safe to see (a masked password, a name) — so
/// the interaction model genuinely differs, not just the visuals. If a shared `KeyValueRow` lands in
/// `App/Sources/Shared/` (851-2463/the New Password worker) with an equivalent "whole row is the
/// click target" mode, swap it in here; every call site below only depends on `configure` and
/// `onCopy`.
@MainActor
final class MenuBarCopyableRowView: NSView {
  /// Called on every click. This view never holds the real secret itself (it only ever displays
  /// masked dots or the current TOTP code) — the caller closes over the actual `PasswordItem` and
  /// puts the right value on the pasteboard via `Pasteboard.copySecret`.
  var onCopy: (() -> Void)?

  private let labelField = NSTextField(labelWithString: "")
  private let valueField = NSTextField(labelWithString: "")
  private let ring = CountdownRingView()
  private let trailingStack = NSStackView()
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
    wantsLayer = true

    labelField.font = .systemFont(ofSize: 13)
    labelField.setContentHuggingPriority(.required, for: .horizontal)
    labelField.translatesAutoresizingMaskIntoConstraints = false

    valueField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    valueField.textColor = .secondaryLabelColor
    valueField.alignment = .right
    valueField.lineBreakMode = .byTruncatingMiddle
    valueField.translatesAutoresizingMaskIntoConstraints = false

    ring.translatesAutoresizingMaskIntoConstraints = false
    ring.isHidden = true
    ring.widthAnchor.constraint(equalToConstant: 14).isActive = true
    ring.heightAnchor.constraint(equalToConstant: 14).isActive = true

    trailingStack.orientation = .horizontal
    trailingStack.alignment = .centerY
    trailingStack.spacing = 6
    trailingStack.addArrangedSubview(ring)
    trailingStack.addArrangedSubview(valueField)
    trailingStack.translatesAutoresizingMaskIntoConstraints = false

    addSubview(labelField)
    addSubview(trailingStack)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 32),

      labelField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      labelField.centerYAnchor.constraint(equalTo: centerYAnchor),

      trailingStack.leadingAnchor.constraint(greaterThanOrEqualTo: labelField.trailingAnchor, constant: 8),
      trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      trailingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    let click = NSClickGestureRecognizer(target: self, action: #selector(rowTapped))
    addGestureRecognizer(click)
  }

  /// - Parameters:
  ///   - showRing: Whether the trailing countdown ring is visible. Only the verification-code row
  ///     has one; its fraction is kept current by ``updateRingFraction(_:)``, called every second
  ///     by `MenuBarItemDetailViewController`'s existing TOTP timer (it already recomputes the
  ///     remaining-seconds title every second, so no second timer is introduced here).
  func configure(label: String, value: String, showRing: Bool) {
    labelField.stringValue = label
    valueField.stringValue = value
    ring.isHidden = !showRing

    // This whole row is the click target for copying its secret (see the type doc comment above
    // for why), but it's a plain `NSView` with only a click gesture recognizer — with nothing
    // else set, VoiceOver would just read `labelField`/`valueField` as inert text and never learn
    // the row is actionable (851-2426). Exposing it as its own accessibility button element fixes
    // that; `value` is always something already safe to say aloud (masked dots or a live code),
    // never a revealed secret at rest.
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(String(localized: "\(label): \(value)"))
  }

  func updateRingFraction(_ fraction: Double) {
    ring.fraction = fraction
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
    layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.12).cgColor
  }

  override func mouseExited(with event: NSEvent) {
    layer?.backgroundColor = nil
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  @objc
  private func rowTapped() {
    onCopy?()
    CopyHUD.show(relativeTo: bounds, of: self)
  }
}
