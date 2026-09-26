import AppKit

/// An `NSButton` for a "fades in on hover" affordance (`DetailValueRowView`'s and
/// `VerificationCodeRowView`'s Copy buttons) that must still be reachable by keyboard and
/// VoiceOver even when the mouse isn't over it.
///
/// The naive way to build a hover-reveal button is `isHidden = true` at rest, flipped by the
/// containing view's `mouseEntered`/`mouseExited`. That's what both call sites originally did —
/// and it's exactly what 851-2426's tophat accessibility audit (AppleScript `System Events`
/// walk of the live accessibility tree) caught: an `isHidden` view is removed from hit-testing,
/// the key view loop, *and* the accessibility tree, so the button was unreachable by Tab or
/// VoiceOver at rest — a keyboard-only or VoiceOver user could never copy a username or password
/// from the detail pane at all. `MenuBarCopyableRowView` (also 851-2426) solved a related but
/// different problem — a plain `NSView` with zero accessibility exposure — by always exposing an
/// AX element; this fixes the actual hover-reveal case by keeping the button un-hidden and
/// controlling its visibility with `alphaValue` instead, which leaves it hit-testable, tabbable,
/// and AX-visible at every moment, hover or not.
///
/// `alphaValue` alone would still leave one gap: a sighted keyboard-only user tabbing to the
/// button would land on something invisible. ``isHovering`` and first-responder status are
/// therefore combined — the button reveals itself on hover *or* while it holds keyboard focus.
final class HoverRevealButton: NSButton {
  /// Set by the containing view's `mouseEntered`/`mouseExited`.
  var isHovering = false {
    didSet {
      guard isHovering != oldValue else { return }
      updateVisibility()
    }
  }

  /// Whether this button can ever be shown at all — e.g. there's nothing to copy yet (no
  /// verification code set up). `false` fully hides it (matching the old permanently-hidden
  /// behavior for that case); `true` makes visibility hover/focus-driven instead of ever hidden.
  var isEligible = true {
    didSet {
      guard isEligible != oldValue else { return }
      isHidden = !isEligible
      updateVisibility()
    }
  }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became { updateVisibility() }
    return became
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned { updateVisibility() }
    return resigned
  }

  private func updateVisibility() {
    guard isEligible else { return }
    alphaValue = (isHovering || window?.firstResponder === self) ? 1 : 0
  }
}
