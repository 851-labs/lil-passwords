import LilPasswordsKit
import SwiftUI

/// Onboarding step 4 (851-2439): walks through exporting a CSV from Apple's Passwords app, then
/// hands off to the existing "File → Import Passwords…" flow (``ImportFlow``) — this step never
/// parses a CSV itself. Skippable: there's nothing here a user is required to do.
struct OnboardingImportView: View {
  var onImportCSV: () -> Void
  var onSkip: () -> Void

  var body: some View {
    OnboardingPageView(
      icon: .symbol(name: "square.and.arrow.down.on.square.fill", tint: .indigo),
      title: String(localized: "Import from Apple Passwords"),
      subtitle: String(localized: "Bring over what you've already saved in Passwords:"),
      content: {
        VStack(alignment: .leading, spacing: 6) {
          OnboardingStepRow(number: 1, text: String(localized: "Open the Passwords app"))
          OnboardingStepRow(number: 2, text: String(localized: "Choose File → Export All Passwords…"))
          OnboardingStepRow(number: 3, text: String(localized: "Authenticate, then save the CSV file"))
          OnboardingStepRow(number: 4, text: String(localized: "Import that file below"))
        }
      },
      primaryTitle: String(localized: "Import CSV…"),
      primaryAction: onImportCSV,
      secondaryTitle: String(localized: "Skip"),
      secondaryAction: onSkip
    )
  }
}

/// One numbered line of the export walkthrough — plain text is enough here; this is guidance for
/// a different app's UI, not something this app needs to illustrate.
private struct OnboardingStepRow: View {
  let number: Int
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Text("\(number).")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 16, alignment: .trailing)
      Text(text)
        .font(.system(size: 12))
      Spacer(minLength: 0)
    }
    // 851-2466: without this, VoiceOver reads the number and the instruction as two separate
    // elements ("1." then, on a second stop, "Open the Passwords app") — combine them into the
    // one sentence a sighted reader gets in a single glance, e.g. "1. Open the Passwords app".
    .accessibilityElement(children: .combine)
  }
}
