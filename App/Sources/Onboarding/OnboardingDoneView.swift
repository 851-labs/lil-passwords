import LilPasswordsKit
import SwiftUI

/// Onboarding step 6 (851-2439): the final "you're set up" screen. Its primary button is the only
/// way this window closes on the happy path — `OnboardingWindowController` treats it as "finished"
/// and marks `AppSettings.hasCompletedOnboarding`.
struct OnboardingDoneView: View {
  var onOpenMainWindow: () -> Void

  var body: some View {
    OnboardingPageView(
      icon: .symbol(name: "checkmark.seal.fill", tint: .green),
      title: "You're All Set",
      subtitle: "Start saving, generating, and autofilling your passwords.",
      content: { EmptyView() },
      primaryTitle: "Open \(LilPasswordsKit.productName)",
      primaryAction: onOpenMainWindow
    )
  }
}
