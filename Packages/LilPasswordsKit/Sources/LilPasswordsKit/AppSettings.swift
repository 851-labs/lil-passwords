import Foundation

/// Persisted app settings, backed by a shared `UserDefaults` suite rather than `.standard`.
///
/// The app isn't sandboxed (see `docs/adr/0001-storage-and-process-model.md`), so any process
/// that knows the suite name can read the same domain: `LilPasswordsAgent` reads
/// ``autoLockInterval``/``clipboardClearInterval`` to enforce them (851-2411, 851-2423), and
/// `lilpass` can do the same. The app is the only writer today — everything here is edited from the
/// Settings window (851-2424).
///
/// The 851-2428 agent-access toggles are **not** stored here — see ``suiteName``'s documentation
/// for why a security-sensitive, any-process-writable preference needed a different home.
public final class AppSettings: @unchecked Sendable {
  /// The default, shared instance every process should use unless a test needs isolation.
  public static let shared = AppSettings()

  /// The `UserDefaults` suite name shared by the app, `LilPasswordsAgent`, and `lilpass`.
  ///
  /// Deliberately distinct from the app's own bundle identifier (`com.851labs.lilpasswords`):
  /// passing an app's own bundle ID as `UserDefaults(suiteName:)` is documented as nonsensical —
  /// it logs a warning and behaves like `.standard` — because the app's own domain is already
  /// its default search location. A dedicated suite name is what actually makes the domain
  /// readable by the other two (differently-bundle-ID'd) processes.
  ///
  /// This suite is, by construction, readable *and freely writable* by any local process that
  /// knows its name — which is exactly why the 851-2428 agent-access settings
  /// (`agentAccessEnabled`/`keepAgentAccessAvailableWhileMacUnlocked`) don't live here: see
  /// `AgentSettingsStoring` and docs/adr/0001-storage-and-process-model.md (e). Only
  /// non-security preferences (auto-lock, clipboard, password-generation defaults) belong in this
  /// suite.
  public static let suiteName = "com.851labs.lilpasswords.shared"

  /// Posted on the default `NotificationCenter` (main queue not guaranteed) whenever any setting
  /// changes, so long-lived observers like the helper's policy checker can react without polling.
  public static let didChangeNotification = Notification.Name("com.851labs.lilpasswords.AppSettingsDidChange")

  /// How long the app may sit idle before it locks itself. Enforcement lands in 851-2411.
  public enum AutoLockInterval: String, CaseIterable, Identifiable, Sendable {
    case immediately
    case oneMinute
    case fiveMinutes
    case fifteenMinutes
    case oneHour
    case never

    public var id: String { rawValue }

    /// Label shown in the Security settings popup.
    public var displayName: String {
      switch self {
      case .immediately: "Immediately"
      case .oneMinute: "After 1 Minute"
      case .fiveMinutes: "After 5 Minutes"
      case .fifteenMinutes: "After 15 Minutes"
      case .oneHour: "After 1 Hour"
      case .never: "Never"
      }
    }

    /// Idle time before auto-lock, or `nil` for `.never`.
    public var timeInterval: TimeInterval? {
      switch self {
      case .immediately: 0
      case .oneMinute: 60
      case .fiveMinutes: 5 * 60
      case .fifteenMinutes: 15 * 60
      case .oneHour: 60 * 60
      case .never: nil
      }
    }
  }

  /// How long a password stays on the clipboard after being copied. Enforcement lands in
  /// 851-2423.
  public enum ClipboardClearInterval: String, CaseIterable, Identifiable, Sendable {
    case never
    case tenSeconds
    case thirtySeconds
    case oneMinute
    case twoMinutes

    public var id: String { rawValue }

    /// Label shown in the Security settings popup.
    public var displayName: String {
      switch self {
      case .never: "Never"
      case .tenSeconds: "After 10 Seconds"
      case .thirtySeconds: "After 30 Seconds"
      case .oneMinute: "After 1 Minute"
      case .twoMinutes: "After 2 Minutes"
      }
    }

    /// Delay before the clipboard is cleared, or `nil` for `.never`.
    public var timeInterval: TimeInterval? {
      switch self {
      case .never: nil
      case .tenSeconds: 10
      case .thirtySeconds: 30
      case .oneMinute: 60
      case .twoMinutes: 120
      }
    }
  }

  private enum Key {
    static let autoLockInterval = "AppSettings.autoLockInterval"
    static let clipboardClearInterval = "AppSettings.clipboardClearInterval"
    static let defaultPasswordLength = "AppSettings.defaultPasswordLength"
    static let includeSymbolsInGeneratedPasswords = "AppSettings.includeSymbolsInGeneratedPasswords"
    static let warnAboutCompromisedPasswords = "AppSettings.warnAboutCompromisedPasswords"
    static let showInMenuBar = "AppSettings.showInMenuBar"
    static let menuBarBrowserSuggestionsEnabled = "AppSettings.menuBarBrowserSuggestionsEnabled"
  }

  /// Smallest and largest custom password length offered in Settings → General.
  public static let passwordLengthRange = 8...64

  private let defaults: UserDefaults

  /// Creates settings backed by `defaults`. Pass an explicit `UserDefaults` (e.g. one scoped to
  /// a throwaway suite name) in tests to avoid polluting — or being polluted by — real app
  /// preferences; production code should use ``shared``.
  public init(defaults: UserDefaults = UserDefaults(suiteName: AppSettings.suiteName) ?? .standard) {
    self.defaults = defaults
    // A literal, built fresh per call rather than a shared static, so it's not flagged as
    // non-`Sendable` global mutable state under strict concurrency.
    defaults.register(defaults: [
      Key.autoLockInterval: AutoLockInterval.fiveMinutes.rawValue,
      Key.clipboardClearInterval: ClipboardClearInterval.thirtySeconds.rawValue,
      Key.defaultPasswordLength: 20,
      Key.includeSymbolsInGeneratedPasswords: true,
      Key.warnAboutCompromisedPasswords: true,
      Key.showInMenuBar: true,
      Key.menuBarBrowserSuggestionsEnabled: false,
    ])
  }

  /// How long the app may sit idle before it locks itself.
  public var autoLockInterval: AutoLockInterval {
    get { AutoLockInterval(rawValue: defaults.string(forKey: Key.autoLockInterval) ?? "") ?? .fiveMinutes }
    set { set(newValue.rawValue, forKey: Key.autoLockInterval) }
  }

  /// How long a copied password stays on the clipboard before it's cleared.
  public var clipboardClearInterval: ClipboardClearInterval {
    get {
      ClipboardClearInterval(rawValue: defaults.string(forKey: Key.clipboardClearInterval) ?? "") ?? .thirtySeconds
    }
    set { set(newValue.rawValue, forKey: Key.clipboardClearInterval) }
  }

  /// Length used for new generated passwords when the "no symbols"/custom format is requested,
  /// clamped to ``passwordLengthRange``.
  public var defaultPasswordLength: Int {
    get {
      let stored = defaults.integer(forKey: Key.defaultPasswordLength)
      let value = stored == 0 ? 20 : stored
      return Self.passwordLengthRange.clamp(value)
    }
    set { set(Self.passwordLengthRange.clamp(newValue), forKey: Key.defaultPasswordLength) }
  }

  /// Whether generated passwords may include symbol characters.
  public var includeSymbolsInGeneratedPasswords: Bool {
    get { defaults.bool(forKey: Key.includeSymbolsInGeneratedPasswords) }
    set { set(newValue, forKey: Key.includeSymbolsInGeneratedPasswords) }
  }

  /// Whether the Security sidebar category should surface weak/reused password warnings.
  public var warnAboutCompromisedPasswords: Bool {
    get { defaults.bool(forKey: Key.warnAboutCompromisedPasswords) }
    set { set(newValue, forKey: Key.warnAboutCompromisedPasswords) }
  }

  // Settings → Agents' two toggles ("Allow agents to access passwords" and "keep agent access
  // available while the Mac is unlocked") are deliberately *not* here — see ``suiteName``'s
  // documentation. They're owned by `LilPasswordsAgent` itself, in an `AgentSettingsStoring`
  // Keychain item, and read/written exclusively through `AgentClient.agentSettings()`/
  // `.setAgentSettings(_:)` (851-2428).

  /// Settings → General → "Show in menu bar" (851-2425): whether `AppDelegate` shows the
  /// `NSStatusItem` menu bar extra at all. On by default, matching Apple Passwords.
  public var showInMenuBar: Bool {
    get { defaults.bool(forKey: Key.showInMenuBar) }
    set { set(newValue, forKey: Key.showInMenuBar) }
  }

  /// Settings → General → "Suggest passwords for the current website" (851-2425): whether the
  /// menu bar extra's "Suggested" section is allowed to ask the frontmost browser for its current
  /// site via AppleScript. Off by default — reading another app's front URL is the kind of
  /// cross-app access a user should opt into deliberately, and doing so the first time prompts for
  /// Automation permission (System Settings → Privacy & Security → Automation), which shouldn't
  /// happen out of the box.
  public var menuBarBrowserSuggestionsEnabled: Bool {
    get { defaults.bool(forKey: Key.menuBarBrowserSuggestionsEnabled) }
    set { set(newValue, forKey: Key.menuBarBrowserSuggestionsEnabled) }
  }

  // Settings → Agents → "Allow agents to create, edit, and delete passwords" (851-2433) is
  // deliberately **not** a property here, for the same reason `agentAccessEnabled`/
  // `keepAgentAccessAvailableWhileMacUnlocked` aren't (see this file's top-level doc comment and
  // ``suiteName``'s): it's a security-sensitive toggle that a hostile local process could otherwise
  // flip back on with a plain `defaults write com.851labs.lilpasswords.shared ...` — this suite is,
  // by design, world-readable *and* world-writable to any process that knows its name. It instead
  // lives as `AgentSettings.agentWriteAccessEnabled`, alongside those other two fields in the same
  // helper-owned, ACL'd Keychain item, gated by verified caller identity and read/written only via
  // `AgentRequest.getAgentSettings`/`.setAgentSettings` — see `AgentSettingsStoring`'s doc comment
  // for the full rationale.

  private func set(_ value: some Any, forKey key: String) {
    defaults.set(value, forKey: key)
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }
}

extension ClosedRange where Bound == Int {
  fileprivate func clamp(_ value: Int) -> Int {
    Swift.min(Swift.max(value, lowerBound), upperBound)
  }
}
