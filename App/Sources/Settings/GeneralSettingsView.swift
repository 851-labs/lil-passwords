import LilPasswordsKit
import SwiftUI

/// Settings → General: preferences for newly generated passwords, security nudges, and the menu
/// bar extra (851-2425). Auto-lock and clipboard timing live in `SecuritySettingsView`; agent
/// access lives in `AgentsSettingsView` (851-2424).
///
/// A grouped `Form` (851-2460), matching System Settings' own presentation: label-left controls,
/// section footers carrying the explanatory text the old hand-rolled AppKit layout used captions
/// for.
struct GeneralSettingsView: View {
  @ObservedObject var settings: ObservableAppSettings

  var body: some View {
    Form {
      Section {
        Stepper(
          "New password length: \(settings.defaultPasswordLength) characters",
          value: $settings.defaultPasswordLength,
          in: AppSettings.passwordLengthRange
        )
        Toggle("Include symbols (!@#$…)", isOn: $settings.includeSymbolsInGeneratedPasswords)
          .toggleStyle(.switch)
      } header: {
        Text("New Passwords")
      } footer: {
        Text("Applies to the custom password format; Apple's Strong Password suggestion is always 20 characters.")
      }

      Section {
        Toggle("Warn about compromised or reused passwords", isOn: $settings.warnAboutCompromisedPasswords)
          .toggleStyle(.switch)
      } header: {
        Text("Security Recommendations")
      }

      // 851-2425. "Show in menu bar" is the actual visibility toggle for the `NSStatusItem`;
      // browser suggestions are a separate opt-in since they need the app to read another app's
      // frontmost tab via AppleScript, which prompts for Automation permission the first time.
      Section {
        Toggle("Show in menu bar", isOn: $settings.showInMenuBar)
          .toggleStyle(.switch)
        Toggle("Suggest passwords for the current website", isOn: $settings.menuBarBrowserSuggestionsEnabled)
          .toggleStyle(.switch)
      } header: {
        Text("Menu Bar")
      } footer: {
        Text(
          "Suggestions ask Safari, Chrome, Arc, or Brave for the site in the frontmost tab, and may prompt for "
            + "Automation permission the first time.")
      }
    }
    .formStyle(.grouped)
    .controlSize(.small)
    .frame(width: SettingsLayout.contentWidth)
    .fixedSize(horizontal: false, vertical: true)
  }
}
