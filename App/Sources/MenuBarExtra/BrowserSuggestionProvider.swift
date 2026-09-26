import AppKit
import LilPasswordsKit

/// Detects the current site of the frontmost browser (Safari, Chrome, Arc, Brave) for the menu
/// bar extra's "Suggested" section (851-2425), matching Apple Passwords' own menu bar extra.
///
/// Off by default (`AppSettings.menuBarBrowserSuggestionsEnabled`): asking another app for its
/// frontmost tab's URL is cross-app access a user should opt into deliberately, and the very
/// first AppleScript send to a given browser prompts for Automation permission (System Settings →
/// Privacy & Security → Automation) — something that should never happen unprompted just because
/// the menu bar extra's popover was opened.
@MainActor
enum BrowserSuggestionProvider {
  private struct Browser {
    let bundleIdentifiers: Set<String>
    let scriptTemplate: String
  }

  private static let safari = Browser(
    bundleIdentifiers: ["com.apple.Safari"],
    scriptTemplate: #"tell application "Safari" to return URL of front document"#
  )

  /// Every Chromium-derived browser scripts the same way: `URL of active tab of front window`,
  /// sent to the app by its own display name (`%@`) so this one template covers all of them.
  private static let chromiumFamily = Browser(
    bundleIdentifiers: [
      "com.google.Chrome",
      "com.google.Chrome.beta",
      "com.brave.Browser",
      "company.thebrowser.Browser",  // Arc
    ],
    scriptTemplate: #"tell application "%@" to return URL of active tab of front window"#
  )

  /// The frontmost browser's current-tab URL, or `nil` if the setting is off, the frontmost app
  /// isn't a recognized browser, or anything about the AppleScript round trip fails (permission
  /// denied, no open window, the app isn't actually scriptable, etc). Every failure mode is
  /// treated identically — "no suggestion available" — which is why every throwing step below is
  /// guarded with `try?` rather than surfaced anywhere.
  static func currentBrowserURL(settings: AppSettings = .shared) -> URL? {
    guard settings.menuBarBrowserSuggestionsEnabled else { return nil }
    guard let frontApp = NSWorkspace.shared.frontmostApplication, let bundleIdentifier = frontApp.bundleIdentifier
    else {
      return nil
    }

    if safari.bundleIdentifiers.contains(bundleIdentifier) {
      return try? runAppleScript(safari.scriptTemplate)
    }
    if chromiumFamily.bundleIdentifiers.contains(bundleIdentifier), let appName = frontApp.localizedName {
      return try? runAppleScript(String(format: chromiumFamily.scriptTemplate, appName))
    }
    return nil
  }

  private struct ScriptError: Error {}

  private static func runAppleScript(_ source: String) throws -> URL {
    guard let script = NSAppleScript(source: source) else { throw ScriptError() }
    var errorInfo: NSDictionary?
    let descriptor = script.executeAndReturnError(&errorInfo)
    guard errorInfo == nil, let string = descriptor.stringValue, let url = URL(string: string) else {
      throw ScriptError()
    }
    return url
  }
}
