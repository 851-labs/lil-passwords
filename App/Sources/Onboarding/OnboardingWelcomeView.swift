import LilPasswordsKit
import SwiftUI

/// Onboarding step 1 (851-2439): the "Welcome to lil passwords" screen, matching Apple's own
/// welcome screens — the app's icon, a bold title, and three short feature bullets — before
/// anything about the vault itself is asked of the user.
struct OnboardingWelcomeView: View {
  var onContinue: () -> Void

  var body: some View {
    OnboardingPageView(
      icon: .appIcon,
      title: String(localized: "Welcome to \(LilPasswordsKit.productName)"),
      subtitle: String(localized: "Let's get you set up."),
      content: {
        VStack(alignment: .leading, spacing: 14) {
          OnboardingFeatureBullet(
            symbolName: "lock.shield.fill",
            tint: .blue,
            title: String(localized: "A local, encrypted vault")
          )
          OnboardingFeatureBullet(
            symbolName: "qrcode",
            tint: .purple,
            title: String(localized: "Verification codes, right alongside your passwords")
          )
          OnboardingFeatureBullet(
            symbolName: "terminal.fill",
            tint: .orange,
            title: String(localized: "A CLI and MCP server for your agents")
          )
        }
        .padding(.top, 4)
      },
      primaryTitle: String(localized: "Continue"),
      primaryAction: onContinue
    )
  }
}
