import AppKit
import LilPasswordsKit
import SwiftUI

/// Hosts `SecuritySettingsView` (851-2460): Settings → Security.
///
/// Constructs its own `AgentClient`, matching `AgentsSettingsViewController`'s
/// per-consumer-instance pattern (see that type's documentation) rather than requiring
/// `SettingsWindowController`/`SettingsTabViewController` — both currently parameterless — to
/// thread a shared instance through. 851-2462's "Generate New Recovery Key…" row needs one to
/// drive `RegenerateRecoveryKeyFlow.present(agentClient:over:)`.
@MainActor
final class SecuritySettingsViewController: NSHostingController<SecuritySettingsView> {
  private let agentClient: AgentClient

  init(settings: AppSettings = .shared, agentClient: AgentClient = AgentClient()) {
    self.agentClient = agentClient
    super.init(
      rootView: SecuritySettingsView(
        settings: ObservableAppSettings(settings: settings),
        onGenerateNewRecoveryKey: {}
      )
    )
    sizingOptions = [.intrinsicContentSize]
    // Can't reference `self` in the closure passed to `super.init(rootView:)` above, so the real
    // closure is wired up here instead, once `self` exists.
    rootView.onGenerateNewRecoveryKey = { [weak self] in self?.presentRegenerateRecoveryKeyFlow() }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Presents over whichever window this view controller is actually installed in — in practice
  /// always `SettingsWindowController`'s shared Settings window, not the main document window.
  private func presentRegenerateRecoveryKeyFlow() {
    guard let window = view.window else { return }
    RegenerateRecoveryKeyFlow.present(agentClient: agentClient, over: window)
  }
}
