import AppKit
import LilPasswordsKit
import SwiftUI

/// Hosts `AgentsSettingsView` (851-2460): Settings → Agents — the access toggle (851-2428) and the
/// access log (851-2429).
///
/// Constructs its own `AgentClient`, matching this codebase's existing per-consumer-instance
/// pattern (e.g. `AppDelegate`'s own `agentClient`, `StatusCommand`'s own `AgentClient()` in the
/// CLI) rather than requiring `SettingsWindowController`/`SettingsTabViewController` — both
/// currently parameterless — to thread a shared instance through.
@MainActor
final class AgentsSettingsViewController: NSHostingController<AgentsSettingsView> {
  init(client: AgentClient = AgentClient()) {
    super.init(rootView: AgentsSettingsView(client: client))
    sizingOptions = [.intrinsicContentSize]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }
}
