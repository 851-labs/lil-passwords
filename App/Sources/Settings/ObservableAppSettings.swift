import Combine
import LilPasswordsKit

/// Bridges `AppSettings` — a plain class backed by a shared `UserDefaults` suite, so it can be
/// read the same way from the app, the helper, and `lilpass` (see its documentation) — into an
/// `ObservableObject` the SwiftUI settings panes (851-2460) can bind to directly with `$`.
///
/// The app is the only writer of these settings today (`AppSettings`'s own doc comment), so this
/// only needs to go one way: every `didSet` below writes straight through to `AppSettings`, which
/// persists it and posts `AppSettings.didChangeNotification` for any other in-process observer.
/// There's no need to also listen for that notification here and mirror it back — that would
/// just be this object echoing its own writes.
@MainActor
final class ObservableAppSettings: ObservableObject {
  private let settings: AppSettings

  @Published var autoLockInterval: AppSettings.AutoLockInterval {
    didSet { settings.autoLockInterval = autoLockInterval }
  }

  @Published var clipboardClearInterval: AppSettings.ClipboardClearInterval {
    didSet { settings.clipboardClearInterval = clipboardClearInterval }
  }

  @Published var defaultPasswordLength: Int {
    didSet { settings.defaultPasswordLength = defaultPasswordLength }
  }

  @Published var includeSymbolsInGeneratedPasswords: Bool {
    didSet { settings.includeSymbolsInGeneratedPasswords = includeSymbolsInGeneratedPasswords }
  }

  @Published var warnAboutCompromisedPasswords: Bool {
    didSet { settings.warnAboutCompromisedPasswords = warnAboutCompromisedPasswords }
  }

  @Published var showInMenuBar: Bool {
    didSet { settings.showInMenuBar = showInMenuBar }
  }

  @Published var menuBarBrowserSuggestionsEnabled: Bool {
    didSet { settings.menuBarBrowserSuggestionsEnabled = menuBarBrowserSuggestionsEnabled }
  }

  // The 851-2428 agent-access toggles are deliberately not bridged here: they no longer live in
  // `AppSettings`/the shared `UserDefaults` suite at all (see that class's documentation). Settings
  // → Agents binds to `AgentSettingsViewModel`, which reads/writes them through `AgentClient`
  // instead.

  init(settings: AppSettings = .shared) {
    self.settings = settings
    autoLockInterval = settings.autoLockInterval
    clipboardClearInterval = settings.clipboardClearInterval
    defaultPasswordLength = settings.defaultPasswordLength
    includeSymbolsInGeneratedPasswords = settings.includeSymbolsInGeneratedPasswords
    warnAboutCompromisedPasswords = settings.warnAboutCompromisedPasswords
    showInMenuBar = settings.showInMenuBar
    menuBarBrowserSuggestionsEnabled = settings.menuBarBrowserSuggestionsEnabled
  }
}
