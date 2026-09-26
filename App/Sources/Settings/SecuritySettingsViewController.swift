import AppKit
import LilPasswordsKit
import SwiftUI

/// Hosts `SecuritySettingsView` (851-2460): Settings → Security.
@MainActor
final class SecuritySettingsViewController: NSHostingController<SecuritySettingsView> {
  init(settings: AppSettings = .shared) {
    super.init(rootView: SecuritySettingsView(settings: ObservableAppSettings(settings: settings)))
    sizingOptions = [.intrinsicContentSize]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }
}
