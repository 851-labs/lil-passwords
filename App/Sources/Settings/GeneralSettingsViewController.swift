import AppKit
import LilPasswordsKit

/// Settings → General: preferences for newly generated passwords, security nudges, and the menu
/// bar extra (851-2425). Auto-lock and clipboard timing live in `SecuritySettingsViewController`;
/// agent access lives in `AgentsSettingsViewController` (851-2424).
@MainActor
final class GeneralSettingsViewController: NSViewController {
  private let settings: AppSettings

  private let lengthStepper = NSStepper()
  private let lengthValueLabel = NSTextField(labelWithString: "")
  private let symbolsCheckbox = NSButton(checkboxWithTitle: "Include symbols (!@#$…)", target: nil, action: nil)
  private let warnCheckbox = NSButton(
    checkboxWithTitle: "Warn about compromised or reused passwords",
    target: nil,
    action: nil
  )
  private let showInMenuBarCheckbox = NSButton(checkboxWithTitle: "Show in menu bar", target: nil, action: nil)
  private let menuBarBrowserSuggestionsCheckbox = NSButton(
    checkboxWithTitle: "Suggest passwords for the current website",
    target: nil,
    action: nil
  )

  init(settings: AppSettings = .shared) {
    self.settings = settings
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func loadView() {
    let lengthRow = NSStackView(views: [
      SettingsLayout.rowLabel("New password length:"), lengthStepper, lengthValueLabel,
    ])
    lengthRow.orientation = .horizontal
    lengthRow.spacing = 8
    lengthRow.alignment = .firstBaseline

    lengthStepper.minValue = Double(AppSettings.passwordLengthRange.lowerBound)
    lengthStepper.maxValue = Double(AppSettings.passwordLengthRange.upperBound)
    lengthStepper.increment = 1
    lengthStepper.target = self
    lengthStepper.action = #selector(lengthChanged(_:))

    symbolsCheckbox.target = self
    symbolsCheckbox.action = #selector(symbolsToggled(_:))

    warnCheckbox.target = self
    warnCheckbox.action = #selector(warnToggled(_:))

    showInMenuBarCheckbox.target = self
    showInMenuBarCheckbox.action = #selector(showInMenuBarToggled(_:))

    menuBarBrowserSuggestionsCheckbox.target = self
    menuBarBrowserSuggestionsCheckbox.action = #selector(menuBarBrowserSuggestionsToggled(_:))

    view = SettingsLayout.makeStack([
      SettingsLayout.sectionHeader("New Passwords"),
      lengthRow,
      symbolsCheckbox,
      SettingsLayout.caption(
        "Applies to the custom password format; Apple's Strong Password suggestion is always 20 characters."),
      SettingsLayout.sectionHeader("Security Recommendations"),
      warnCheckbox,
      // 851-2425. "Show in menu bar" is the actual visibility toggle for the `NSStatusItem`;
      // browser suggestions are a separate opt-in since they need the app to read another app's
      // frontmost tab via AppleScript, which prompts for Automation permission the first time.
      SettingsLayout.sectionHeader("Menu Bar"),
      showInMenuBarCheckbox,
      menuBarBrowserSuggestionsCheckbox,
      SettingsLayout.caption(
        "Suggestions ask Safari, Chrome, Arc, or Brave for the site in the frontmost tab, and may prompt for "
          + "Automation permission the first time."),
    ])
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    preferredContentSize = SettingsLayout.preferredSize(for: view)
    loadFromSettings()
  }

  private func loadFromSettings() {
    lengthStepper.integerValue = settings.defaultPasswordLength
    lengthValueLabel.stringValue = "\(settings.defaultPasswordLength) characters"
    symbolsCheckbox.state = settings.includeSymbolsInGeneratedPasswords ? .on : .off
    warnCheckbox.state = settings.warnAboutCompromisedPasswords ? .on : .off
    showInMenuBarCheckbox.state = settings.showInMenuBar ? .on : .off
    menuBarBrowserSuggestionsCheckbox.state = settings.menuBarBrowserSuggestionsEnabled ? .on : .off
  }

  @objc private func lengthChanged(_ sender: NSStepper) {
    settings.defaultPasswordLength = sender.integerValue
    lengthValueLabel.stringValue = "\(settings.defaultPasswordLength) characters"
  }

  @objc private func symbolsToggled(_ sender: NSButton) {
    settings.includeSymbolsInGeneratedPasswords = sender.state == .on
  }

  @objc private func warnToggled(_ sender: NSButton) {
    settings.warnAboutCompromisedPasswords = sender.state == .on
  }

  @objc private func showInMenuBarToggled(_ sender: NSButton) {
    settings.showInMenuBar = sender.state == .on
  }

  @objc private func menuBarBrowserSuggestionsToggled(_ sender: NSButton) {
    settings.menuBarBrowserSuggestionsEnabled = sender.state == .on
  }
}
