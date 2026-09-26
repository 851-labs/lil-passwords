import LilPasswordsKit
import SwiftUI

/// Settings → General: preferences for newly generated passwords and security nudges. Auto-lock
/// and clipboard timing live in `SecuritySettingsView`; agent access lives in `AgentsSettingsView`
/// (851-2424).
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
    }
    .formStyle(.grouped)
    .frame(width: SettingsLayout.contentWidth)
    .fixedSize(horizontal: false, vertical: true)
  }
}
