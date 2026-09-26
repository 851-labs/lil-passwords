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
        Toggle("Detect compromised passwords", isOn: $settings.detectCompromisedPasswords)
          .toggleStyle(.switch)
      } header: {
        Text("Security Recommendations")
      } footer: {
        Text(
          "Checks each password against known data leaks by sending only the first 5 characters of its hash — "
            + "never the password itself — to Have I Been Pwned.")
      }

      // 851-2459. Off by default: fetching an icon tells that site (and anything on the network
      // path to it) that this Mac has an account there.
      Section {
        Toggle("Show website icons", isOn: $settings.showWebsiteIcons)
          .toggleStyle(.switch)
      } header: {
        Text("Website Icons")
      } footer: {
        Text("Fetching icons reveals which sites you have accounts for to those sites.")
      }

      // 851-2441: the AutoFill credential provider extension can't turn itself on — the system
      // only lets the user enable a provider from System Settings, so this is a pointer, not a
      // toggle. See `AutoFillSystemSettings.open()` and
      // docs/adr/0005-autofill-credential-provider.md for why it may not be selectable there yet
      // (the provisioning-profile blocker, 851-2400).
      Section {
        Button("Open AutoFill & Passwords Settings…") {
          AutoFillSystemSettings.open()
        }
      } header: {
        Text("AutoFill")
      } footer: {
        // A single string literal, not `+`-concatenated across lines (`\` inside a triple-quoted
        // literal just suppresses the source newline, it isn't string concatenation): `Text(_:)`
        // only auto-localizes via the String Catalog when it receives one `LocalizedStringKey`
        // literal. `"a" + "b"` type-infers to a plain `String` instead, which silently opts this
        // out of localization/extraction entirely — confirmed missing from
        // App/Resources/Localizable.xcstrings for the pre-existing "Menu Bar" footer just below,
        // which has the same `+`-split shape. Not fixing that pre-existing one here (out of scope
        // for 851-2441), but not repeating its bug in this new section either.
        Text(
          """
          To let Safari and other apps offer lil passwords when filling in a username and password, \
          turn it on in System Settings → General → AutoFill & Passwords.
          """)
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
