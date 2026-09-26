import AppKit
import SwiftUI

/// The fixed content size every onboarding step renders at (851-2439) — the window itself never
/// resizes between steps, matching how Apple's own welcome/Setup Assistant windows stay one size
/// end to end rather than growing and shrinking as you click through.
enum OnboardingLayout {
  static let contentSize = NSSize(width: 560, height: 560)
}

/// The one-icon/bold-title/short-copy/primary-button page shape every onboarding step (851-2439)
/// is built from, in the style of Apple's own welcome screens — kept in one place so all six steps
/// stay visually consistent rather than six hand-rolled layouts drifting apart.
///
/// 851-2466: `title`/`subtitle`/`primaryTitle`/`secondaryTitle` are plain `String`, not
/// `LocalizedStringKey` — `body` below feeds them to `Text(_:)`/`Button(_:action:)` via the
/// verbatim, non-localizing `String` initializers. Every call site must pass an already-resolved
/// `String(localized: "...")`, not a bare literal, or the copy won't be extracted into
/// `Localizable.xcstrings` at all.
struct OnboardingPageView<Content: View>: View {
  var icon: OnboardingIcon
  let title: String
  var subtitle: String?
  @ViewBuilder var content: () -> Content
  var primaryTitle: String
  var primaryAction: () -> Void
  var primaryDisabled: Bool = false
  var isPrimaryLoading: Bool = false
  var secondaryTitle: String?
  var secondaryAction: (() -> Void)?

  var body: some View {
    VStack(spacing: 20) {
      Spacer(minLength: 12)

      // Purely decorative (851-2466): the bold title right below always says in words whatever
      // this icon illustrates ("Create Your Vault" next to a key glyph, "Unlock with Touch ID"
      // next to a Touch ID glyph, etc.), so VoiceOver would otherwise announce the same thing
      // twice — same reasoning as `SidebarIconFactory`'s icons (docs/accessibility.md).
      icon.view
        .accessibilityHidden(true)

      VStack(spacing: 8) {
        Text(title)
          .font(.system(size: 26, weight: .bold))
          .multilineTextAlignment(.center)

        if let subtitle {
          Text(subtitle)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      content()

      Spacer(minLength: 12)

      VStack(spacing: 10) {
        Button(action: primaryAction) {
          if isPrimaryLoading {
            ProgressView()
              .controlSize(.small)
              .frame(maxWidth: .infinity)
          } else {
            Text(primaryTitle)
              .frame(maxWidth: .infinity)
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(primaryDisabled || isPrimaryLoading)
        .keyboardShortcut(.defaultAction)
        // 851-2466: while loading, this button's content is a bare `ProgressView` with no text, so
        // without an explicit label VoiceOver would land on it as an unlabeled (dimmed) button —
        // keep announcing the same title (e.g. "Create Vault") throughout, not just when idle.
        .accessibilityLabel(primaryTitle)

        if let secondaryTitle, let secondaryAction {
          Button(secondaryTitle, action: secondaryAction)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.system(size: 12))
        }
      }
      .frame(width: 280)
    }
    .padding(.horizontal, 48)
    .padding(.vertical, 40)
    .frame(width: OnboardingLayout.contentSize.width, height: OnboardingLayout.contentSize.height)
  }
}

/// The big icon shown at the top of every onboarding step: either the app's own icon (the welcome
/// step, matching how Apple's welcome screens open on the app/product's own icon) or an SF Symbol
/// in a tinted rounded square (every other step, one per topic).
enum OnboardingIcon {
  case appIcon
  case symbol(name: String, tint: Color)

  @ViewBuilder
  var view: some View {
    switch self {
    case .appIcon:
      Image(nsImage: NSApp.applicationIconImage ?? NSImage())
        .resizable()
        .frame(width: 96, height: 96)

    case .symbol(let name, let tint):
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(tint.gradient)
        .frame(width: 84, height: 84)
        .overlay {
          Image(systemName: name)
            .font(.system(size: 36, weight: .medium))
            .foregroundStyle(.white)
        }
    }
  }
}

/// One row of the welcome step's feature list: a small tinted symbol plus a short title, matching
/// the terse "feature bullet" rows Apple's own welcome screens use.
struct OnboardingFeatureBullet: View {
  let symbolName: String
  let tint: Color
  let title: String

  var body: some View {
    HStack(spacing: 12) {
      // Decorative (851-2466): `title` already says the whole feature in words, so the symbol
      // would otherwise be announced as a second, redundant element — see `OnboardingPageView`'s
      // own icon for the same reasoning.
      Image(systemName: symbolName)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 24)
        .accessibilityHidden(true)

      Text(title)
        .font(.system(size: 13, weight: .medium))

      Spacer(minLength: 0)
    }
  }
}
