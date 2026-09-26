import LilPasswordsKit
import SwiftUI

/// Onboarding step 5 (851-2439): optional agent access. Binds the same `AgentSettingsViewModel`
/// Settings → Agents uses (851-2428) — not a separate copy of the setting — so flipping this
/// switch here and later in Settings always agree. Skippable, and off by default
/// (`AgentSettings.disabled`, read via `AgentSettingsViewModel.refresh()`).
struct OnboardingAgentsView: View {
  @ObservedObject var agentSettings: AgentSettingsViewModel

  /// A clear hook for 851-2432 ("install the `lilpass` command"): today this just explains that
  /// it's on the way. Swap this closure's implementation (passed in from
  /// `OnboardingWindowController`) for the real install action once that ticket lands — nothing
  /// else on this screen needs to change.
  var onInstallCLI: () -> Void

  var onContinue: () -> Void
  var onSkip: () -> Void

  var body: some View {
    OnboardingPageView(
      icon: .symbol(name: "sparkles", tint: .pink),
      title: "Agents",
      subtitle:
        "The \(LilPasswordsKit.cliName) CLI and MCP server let your coding agents read your vault. "
        + "Any local process that can run \(LilPasswordsKit.cliName) can read everything while "
        + "\(LilPasswordsKit.productName) is unlocked, and every access is logged.",
      content: {
        VStack(spacing: 14) {
          Toggle("Allow agents to access passwords", isOn: $agentSettings.agentAccessEnabled)
            .toggleStyle(.switch)

          Button("Install \(LilPasswordsKit.cliName) Command…", action: onInstallCLI)
            .buttonStyle(.bordered)
        }
      },
      primaryTitle: "Continue",
      primaryAction: onContinue,
      secondaryTitle: "Skip",
      secondaryAction: onSkip
    )
  }
}
