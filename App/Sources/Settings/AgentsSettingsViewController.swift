import AppKit
import LilPasswordsKit
import SwiftUI

/// Hosts `AgentsSettingsView` (851-2460): Settings → Agents — the access toggle (851-2428) and the
/// access log (851-2429).
@MainActor
final class AgentsSettingsViewController: NSHostingController<AgentsSettingsView> {
  init(settings: AppSettings = .shared) {
    super.init(rootView: AgentsSettingsView(settings: ObservableAppSettings(settings: settings)))
    sizingOptions = [.intrinsicContentSize]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }
}
