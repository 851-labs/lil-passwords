import AppKit
import LilPasswordsKit
import SwiftUI

/// Hosts `GeneralSettingsView` (851-2460): Settings → General, including the menu bar extra
/// preferences (851-2425) `GeneralSettingsView` carries as its own "Menu Bar" section.
@MainActor
final class GeneralSettingsViewController: NSHostingController<GeneralSettingsView> {
  init(settings: AppSettings = .shared) {
    super.init(rootView: GeneralSettingsView(settings: ObservableAppSettings(settings: settings)))
    // Keeps `preferredContentSize` in sync with the SwiftUI content's own ideal size, which is
    // what `SettingsTabViewController.tabView(_:didSelect:)` reads to resize the window per tab —
    // the same "fixed width, height follows content" contract the old AppKit `SettingsLayout`
    // computed by hand.
    sizingOptions = [.intrinsicContentSize]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }
}
