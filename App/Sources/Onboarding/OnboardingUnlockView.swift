import LilPasswordsKit
import SwiftUI

/// Onboarding step 3 (851-2439): explains the lock screen and auto-lock the user is about to see
/// every time they reopen the app, and points at Settings → Security for changing the timing —
/// it doesn't duplicate that picker here.
struct OnboardingUnlockView: View {
  var onOpenSecuritySettings: () -> Void
  var onContinue: () -> Void

  var body: some View {
    OnboardingPageView(
      icon: .symbol(name: "touchid", tint: .green),
      title: "Unlock with Touch ID",
      subtitle:
        "\(LilPasswordsKit.productName) locks itself after a period of inactivity, and unlocks again "
        + "with Touch ID or your Mac password — no separate master password to remember.",
      content: {
        Button("Open Security Settings…", action: onOpenSecuritySettings)
          .buttonStyle(.plain)
          .foregroundStyle(.blue)
          .font(.system(size: 12))
      },
      primaryTitle: "Continue",
      primaryAction: onContinue
    )
  }
}
