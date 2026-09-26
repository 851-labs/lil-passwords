import LilPasswordsKit
import SwiftUI

/// Onboarding step 5 (851-2439): optional agent access. Binds the same `AgentSettingsViewModel`
/// Settings → Agents uses (851-2428) — not a separate copy of the setting — so flipping this
/// switch here and later in Settings always agree. Skippable, and off by default
/// (`AgentSettings.disabled`, read via `AgentSettingsViewModel.refresh()`).
///
/// The "Install lilpass Command…" control binds the same `CLIInstallViewModel`/`CLIInstaller`
/// Settings → Agents → "Command Line Tool" uses (851-2432) — not a separate copy of the install
/// logic — so installing from either place always agrees, and reopening onboarding after an
/// install already made from Settings shows it as already installed.
struct OnboardingAgentsView: View {
  @ObservedObject var agentSettings: AgentSettingsViewModel
  @ObservedObject var cliInstall: CLIInstallViewModel

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

          VStack(spacing: 6) {
            switch cliInstall.status {
            case .notInstalled, .pointsElsewhere:
              Button("Install \(LilPasswordsKit.cliName) Command…") { cliInstall.install() }
                .buttonStyle(.bordered)
            case .installed:
              Label("\(LilPasswordsKit.cliName) Command Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 12, weight: .medium))
            }

            Text(cliInstallStatusText)
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)

            if let lastErrorMessage = cliInstall.lastErrorMessage {
              Text(lastErrorMessage)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
            }
          }
        }
      },
      primaryTitle: "Continue",
      primaryAction: onContinue,
      secondaryTitle: "Skip",
      secondaryAction: onSkip
    )
  }

  /// Mirrors `AgentsSettingsView.cliInstallFooterText`'s wording (kept as a small, deliberate
  /// duplication rather than a shared helper — this page's copy is centered/two-line, Settings'
  /// is a form footer, and the two are unlikely to need to change in lockstep).
  ///
  /// Returned as `String`, not `LocalizedStringKey` — this feeds `Text(_:)` above via the verbatim
  /// `Text(String)` initializer, which does *not* auto-localize, unlike `Text("literal")`'s
  /// `LocalizedStringKey` initializer. Each branch is wrapped in `String(localized:)` individually
  /// so it still gets extracted into the catalog.
  private var cliInstallStatusText: String {
    switch cliInstall.status {
    case .notInstalled:
      return String(localized: "So agents (and you) can use \(LilPasswordsKit.cliName) from a terminal.")
    case .installed(let path) where path.hasPrefix(NSHomeDirectory() + "/.local/bin"):
      return String(
        localized: "Installed to \(path). If your terminal can't find it, add ~/.local/bin to your shell's PATH."
      )
    case .installed(let path):
      return String(localized: "Installed to \(path).")
    case .pointsElsewhere(let path, let target):
      return String(
        localized: "Something else is already at \(path) (pointing to \(target)). Installing will replace it.")
    }
  }
}
