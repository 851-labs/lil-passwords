import AppKit
import LilPasswordsKit
import SwiftUI

/// Hosts `GeneralSettingsView` (851-2460): Settings → General, including the menu bar extra
/// preferences (851-2425) `GeneralSettingsView` carries as its own "Menu Bar" section.
@MainActor
final class GeneralSettingsViewController: NSHostingController<GeneralSettingsView> {
  init(settings: AppSettings = .shared) {
    super.init(rootView: GeneralSettingsView(settings: ObservableAppSettings(settings: settings)))
    // Keeps this hosting controller's own `view.fittingSize` tracking the SwiftUI content's ideal
    // size ("fixed width, height follows content" — the same contract the old AppKit
    // `SettingsLayout` computed by hand). `SettingsTabViewController` reads `fittingSize` (not
    // `preferredContentSize`, which never gets populated for a hosting controller nested under
    // another view controller) to resize the window per tab.
    sizingOptions = [.intrinsicContentSize]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }
}
