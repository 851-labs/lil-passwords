import Foundation
import Testing

@testable import LilPasswordsKit

@Suite("AppSettings")
struct AppSettingsTests {
  /// Each test gets its own throwaway `UserDefaults` suite so tests can't see each other's
  /// (or the real app's) preferences.
  private func makeSettings() -> AppSettings {
    let suiteName = "com.851labs.lilpasswords.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return AppSettings(defaults: defaults)
  }

  @Test("defaults match Apple Passwords-like expectations")
  func defaultValues() {
    let settings = makeSettings()
    #expect(settings.autoLockInterval == .fiveMinutes)
    #expect(settings.clipboardClearInterval == .thirtySeconds)
    #expect(settings.defaultPasswordLength == 20)
    #expect(settings.includeSymbolsInGeneratedPasswords == true)
    #expect(settings.warnAboutCompromisedPasswords == true)
    #expect(settings.showInMenuBar == true)
    #expect(settings.menuBarBrowserSuggestionsEnabled == false)
    #expect(settings.itemListSortField == .title)
    #expect(settings.itemListSortDirection == .ascending)
    #expect(settings.hasCompletedOnboarding == false)
  }

  @Test("round-trips every setting")
  func roundTrip() {
    let settings = makeSettings()

    settings.autoLockInterval = .never
    #expect(settings.autoLockInterval == .never)

    settings.clipboardClearInterval = .oneMinute
    #expect(settings.clipboardClearInterval == .oneMinute)

    settings.defaultPasswordLength = 32
    #expect(settings.defaultPasswordLength == 32)

    settings.includeSymbolsInGeneratedPasswords = false
    #expect(settings.includeSymbolsInGeneratedPasswords == false)

    settings.warnAboutCompromisedPasswords = false
    #expect(settings.warnAboutCompromisedPasswords == false)

    settings.showInMenuBar = false
    #expect(settings.showInMenuBar == false)

    settings.menuBarBrowserSuggestionsEnabled = true
    #expect(settings.menuBarBrowserSuggestionsEnabled == true)

    settings.itemListSortField = .createdAt
    #expect(settings.itemListSortField == .createdAt)

    settings.itemListSortDirection = .descending
    #expect(settings.itemListSortDirection == .descending)

    settings.hasCompletedOnboarding = true
    #expect(settings.hasCompletedOnboarding == true)
  }

  @Test("clamps password length to the supported range")
  func clampsPasswordLength() {
    let settings = makeSettings()

    settings.defaultPasswordLength = 1
    #expect(settings.defaultPasswordLength == AppSettings.passwordLengthRange.lowerBound)

    settings.defaultPasswordLength = 1000
    #expect(settings.defaultPasswordLength == AppSettings.passwordLengthRange.upperBound)
  }

  @Test("auto-lock intervals map to the expected idle durations")
  func autoLockTimeIntervals() {
    #expect(AppSettings.AutoLockInterval.immediately.timeInterval == 0)
    #expect(AppSettings.AutoLockInterval.oneMinute.timeInterval == 60)
    #expect(AppSettings.AutoLockInterval.never.timeInterval == nil)
  }

  @Test("clipboard clear intervals map to the expected durations")
  func clipboardClearTimeIntervals() {
    #expect(AppSettings.ClipboardClearInterval.tenSeconds.timeInterval == 10)
    #expect(AppSettings.ClipboardClearInterval.never.timeInterval == nil)
  }

  @Test("changing a setting posts the change notification")
  func postsChangeNotification() async {
    let settings = makeSettings()
    await confirmation { confirmed in
      let observer = NotificationCenter.default.addObserver(
        forName: AppSettings.didChangeNotification,
        object: settings,
        queue: nil
      ) { _ in
        confirmed()
      }
      defer { NotificationCenter.default.removeObserver(observer) }
      settings.warnAboutCompromisedPasswords = false
    }
  }
}
