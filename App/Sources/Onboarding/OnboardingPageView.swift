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

      icon.view

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
      Image(systemName: symbolName)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 24)

      Text(title)
        .font(.system(size: 13, weight: .medium))

      Spacer(minLength: 0)
    }
  }
}
