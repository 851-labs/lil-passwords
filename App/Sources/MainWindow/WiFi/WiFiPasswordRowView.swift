import AppKit
import LilPasswordsKit

/// The Wi-Fi detail card's password row. Unlike ``PasswordEditRowView`` (which masks a value this
/// process already holds), there's nothing to mask locally at rest — revealing a Wi-Fi password
/// means asking macOS for it for the first time, which triggers the OS's own admin-authentication
/// dialog and can fail or be cancelled. So this is its own small state machine (masked → loading →
/// revealed/failed) rather than a reveal toggle over an always-in-memory value.
///
/// The revealed password is held only by this view, only in memory, for exactly as long as it's
/// displayed — never written to the vault, a log, or disk, and re-masking (tapping reveal again)
/// discards it outright rather than caching it for next time. See `docs/adr/0005-wifi-passwords.md`.
@MainActor
final class WiFiPasswordRowView: NSView {
  /// Set by the owning view controller to `{ try await viewModel.revealPassword(for: network) }`.
  /// Async/throwing so the caller can show macOS's admin-authentication UI and this view never has
  /// to know how that lookup actually happens.
  var onReveal: (() async throws -> String)?
  /// Called with the currently-revealed password when the copy button is tapped. Never called
  /// while masked/loading/failed — `copyButton.isEligible` tracks that.
  var onCopy: ((String) -> Void)?

  private enum State: Equatable {
    case masked
    case loading
    case revealed(String)
    case failed(String)
  }

  private var state: State = .masked {
    didSet { updateForState() }
  }

  private let labelField = NSTextField(labelWithString: String(localized: "Password"))
  private let valueField = NSTextField(labelWithString: "")
  private let progressIndicator = NSProgressIndicator()
  private let revealButton = NSButton(
    image: NSImage(systemSymbolName: "eye", accessibilityDescription: nil) ?? NSImage(),
    target: nil,
    action: nil
  )
  private let copyButton = HoverRevealButton(
    image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: String(localized: "Copy")) ?? NSImage(),
    target: nil,
    action: nil
  )
  private var trackingArea: NSTrackingArea?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureSubviews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Discards any revealed password and returns to the masked state — called by the detail
  /// controller whenever the selected network changes, so switching networks never leaves a
  /// previous network's password on screen (or lets its "Copy" button copy the wrong one).
  func reset() {
    state = .masked
  }

  private func configureSubviews() {
    translatesAutoresizingMaskIntoConstraints = false

    labelField.font = .systemFont(ofSize: 13)
    labelField.setContentHuggingPriority(.required, for: .horizontal)
    labelField.translatesAutoresizingMaskIntoConstraints = false

    valueField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    valueField.textColor = .secondaryLabelColor
    valueField.alignment = .right
    valueField.lineBreakMode = .byTruncatingMiddle
    valueField.translatesAutoresizingMaskIntoConstraints = false

    progressIndicator.style = .spinning
    progressIndicator.controlSize = .small
    progressIndicator.isDisplayedWhenStopped = false
    progressIndicator.translatesAutoresizingMaskIntoConstraints = false

    revealButton.isBordered = false
    revealButton.bezelStyle = .inline
    revealButton.contentTintColor = .secondaryLabelColor
    revealButton.target = self
    revealButton.action = #selector(revealTapped)
    revealButton.translatesAutoresizingMaskIntoConstraints = false

    copyButton.isBordered = false
    copyButton.bezelStyle = .inline
    copyButton.contentTintColor = .secondaryLabelColor
    copyButton.isEligible = false
    copyButton.toolTip = String(localized: "Copy Password")
    copyButton.target = self
    copyButton.action = #selector(copyTapped)
    copyButton.translatesAutoresizingMaskIntoConstraints = false
    copyButton.setAccessibilityLabel(String(localized: "Copy Password"))

    addSubview(labelField)
    addSubview(valueField)
    addSubview(progressIndicator)
    addSubview(revealButton)
    addSubview(copyButton)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 40),

      // 16pt — matches `CardView`'s divider inset and every other row's label/value inset in this
      // card, so this row's text lines up with "Security" and the header above/below it.
      labelField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      labelField.centerYAnchor.constraint(equalTo: centerYAnchor),

      valueField.leadingAnchor.constraint(greaterThanOrEqualTo: labelField.trailingAnchor, constant: 8),
      valueField.centerYAnchor.constraint(equalTo: centerYAnchor),
      valueField.trailingAnchor.constraint(lessThanOrEqualTo: progressIndicator.leadingAnchor, constant: -8),

      progressIndicator.trailingAnchor.constraint(equalTo: revealButton.leadingAnchor, constant: -4),
      progressIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
      progressIndicator.widthAnchor.constraint(equalToConstant: 16),
      progressIndicator.heightAnchor.constraint(equalToConstant: 16),

      revealButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -2),
      revealButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      revealButton.widthAnchor.constraint(equalToConstant: 22),
      revealButton.heightAnchor.constraint(equalToConstant: 22),

      copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      copyButton.widthAnchor.constraint(equalToConstant: 22),
      copyButton.heightAnchor.constraint(equalToConstant: 22),
    ])

    updateForState()
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
    copyButton.isHovering = true
  }

  override func mouseExited(with event: NSEvent) {
    copyButton.isHovering = false
  }

  @objc
  private func revealTapped() {
    switch state {
    case .masked, .failed:
      state = .loading
      Task {
        guard let onReveal else { return }
        do {
          let password = try await onReveal()
          // The row may have been reset (network selection changed) while the reveal — including
          // a real admin-authentication dialog — was in flight; don't clobber that with a stale
          // result for a network that's no longer selected.
          guard case .loading = state else { return }
          state = .revealed(password)
        } catch {
          guard case .loading = state else { return }
          state = .failed(Self.message(for: error))
        }
      }
    case .revealed, .loading:
      state = .masked
    }
  }

  @objc
  private func copyTapped() {
    guard case .revealed(let password) = state else { return }
    onCopy?(password)
    CopyHUD.show(relativeTo: copyButton.bounds, of: copyButton)
  }

  private func updateForState() {
    switch state {
    case .masked:
      valueField.stringValue = Self.maskedPlaceholder
      valueField.textColor = .secondaryLabelColor
      progressIndicator.stopAnimation(nil)
      progressIndicator.isHidden = true
      revealButton.isHidden = false
      setRevealButton(revealed: false)
      copyButton.isEligible = false

    case .loading:
      valueField.stringValue = String(localized: "Authenticating…")
      valueField.textColor = .secondaryLabelColor
      progressIndicator.isHidden = false
      progressIndicator.startAnimation(nil)
      revealButton.isHidden = true
      copyButton.isEligible = false

    case .revealed(let password):
      valueField.stringValue = password
      valueField.textColor = .labelColor
      progressIndicator.stopAnimation(nil)
      progressIndicator.isHidden = true
      revealButton.isHidden = false
      setRevealButton(revealed: true)
      copyButton.isEligible = true

    case .failed(let message):
      valueField.stringValue = message
      valueField.textColor = .systemRed
      progressIndicator.stopAnimation(nil)
      progressIndicator.isHidden = true
      revealButton.isHidden = false
      setRevealButton(revealed: false)
      copyButton.isEligible = false
    }
  }

  private func setRevealButton(revealed: Bool) {
    let label = revealed ? String(localized: "Hide Password") : String(localized: "Reveal Password")
    revealButton.image = NSImage(systemSymbolName: revealed ? "eye.slash" : "eye", accessibilityDescription: label)
    revealButton.toolTip = label
    revealButton.setAccessibilityLabel(label)
  }

  private static let maskedPlaceholder = String(repeating: "•", count: 10)

  /// Maps a reveal failure to user-facing text. `security`'s own exit codes can't reliably tell
  /// "the person cancelled the admin prompt" apart from "the wrong password/some other failure"
  /// (see `WiFiPasswordRevealError`'s doc comment in `LilPasswordsKit`) — every non-`.notFound`
  /// failure gets the same generic message rather than this app guessing at a distinction the
  /// underlying tool doesn't expose.
  private static func message(for error: Error) -> String {
    switch error {
    case WiFiPasswordRevealError.notFound:
      return String(localized: "lil passwords couldn't find a saved password for this network.")
    case WiFiPasswordRevealError.failed:
      return String(
        localized: "Couldn't reveal this network's password. You may need to enter an administrator password."
      )
    default:
      return String(localized: "Couldn't reveal this network's password.")
    }
  }
}
