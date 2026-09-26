import AppKit
import LilPasswordsKit

/// Presents the 851-2445 "ask every time" approval dialog: Allow / Allow for 15 Minutes / Deny,
/// gated by Touch ID (or device-owner authentication), for each request `AgentServer` parks while
/// `AgentAccessScope.askEveryTime` is active.
///
/// Wired the same way `MainWindowController.startObservingLockState()` wires up `LockStateObserver`:
/// a payload-less Darwin notification (`AgentApprovalNotifications`) wakes this controller, which
/// then makes an ordinary forward XPC call (`AgentClient.pendingApprovals()`) to find out what's
/// actually waiting — see docs/adr/0005-scoped-agent-access.md's "Approval flow" section for why the
/// notification itself carries no payload.
@MainActor
final class AgentApprovalController {
  private let agentClient: AgentClient
  private let authenticator: any VaultAuthenticating
  private let presentingWindow: () -> NSWindow?

  private var observer: AgentApprovalObserver?

  /// Guards against presenting a second dialog on top of one already on screen — `checkPendingApprovals()`
  /// re-runs after each resolution instead, so a burst of requests is handled one at a time rather
  /// than stacking sheets.
  private var isPresenting = false

  /// - Parameters:
  ///   - agentClient: Shared with the rest of the app (`AppDelegate.agentClient`) — approvals ride
  ///     the same XPC connection every other request does, per the ADR; there's no reason for this
  ///     controller to open a second one.
  ///   - authenticator: The same `VaultAuthenticating` seam `MainWindowController.makeAuthenticator()`
  ///     already produces for unlock, including its DEBUG `LILPASSWORDS_FAKE_AUTH=1` escape hatch —
  ///     passed in rather than constructed here so both call sites stay driven by one `#if DEBUG`
  ///     check.
  ///   - presentingWindow: Resolved lazily on each dialog, not captured once — the main window may
  ///     not exist yet (or may have been closed) when this controller itself is constructed.
  init(
    agentClient: AgentClient,
    authenticator: any VaultAuthenticating,
    presentingWindow: @escaping () -> NSWindow?
  ) {
    self.agentClient = agentClient
    self.authenticator = authenticator
    self.presentingWindow = presentingWindow
  }

  /// Starts listening for approval requests. Also checks immediately, once, for anything already
  /// pending — e.g. the helper launched this app *because* of a pending approval
  /// (`ApprovalAppLaunching`), so by the time `applicationDidFinishLaunching` gets here, the request
  /// may already be waiting rather than arriving via a fresh notification.
  func startObserving() {
    observer = AgentApprovalObserver { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        self.checkPendingApprovals()
      }
    }
    checkPendingApprovals()
  }

  private func checkPendingApprovals() {
    guard !isPresenting else { return }
    Task { [weak self] in
      guard let self else { return }
      guard let pending = try? await self.agentClient.pendingApprovals(), let next = pending.first else { return }
      await self.present(next)
    }
  }

  private func present(_ summary: PendingApprovalSummary) async {
    isPresenting = true
    defer { isPresenting = false }

    NSApp.activate(ignoringOtherApps: true)

    // Touch ID gates the dialog itself, not just the answer — a locked screen or a "someone else is
    // at the keyboard" moment shouldn't be able to see *or* answer "claude wants to read the
    // password for GitHub" any more than it should be able to unlock the vault outright. A failed
    // or cancelled authentication denies the request outright rather than falling through to the
    // Allow/Deny dialog.
    do {
      try await authenticator.authenticateDeviceOwner(reason: summary.dialogMessage)
    } catch {
      await resolve(summary.id, decision: .deny)
      checkPendingApprovals()
      return
    }

    let decision = await presentAlert(for: summary)
    await resolve(summary.id, decision: decision)

    // A second request may already be waiting (e.g. two calls arrived close together while this one
    // was on screen) — check again immediately rather than waiting on the next Darwin notification,
    // which only fires once per newly-arrived request, not once per still-pending one.
    checkPendingApprovals()
  }

  private func presentAlert(for summary: PendingApprovalSummary) async -> ApprovalDecision {
    await withCheckedContinuation { continuation in
      let alert = Self.makeAlert(for: summary)

      func respond(_ response: NSApplication.ModalResponse) {
        continuation.resume(returning: Self.decision(for: response))
      }

      if let window = presentingWindow(), window.isVisible {
        alert.beginSheetModal(for: window) { response in respond(response) }
      } else {
        respond(alert.runModal())
      }
    }
  }

  /// Builds (but doesn't show) the Allow / Allow for 15 Minutes / Deny alert for `summary`. Split
  /// out from `presentAlert(for:)` so `AgentTophatDebugMenu` can render the exact same dialog for
  /// a screenshot without needing a live `ApprovalCenter`/XPC round trip behind it.
  static func makeAlert(for summary: PendingApprovalSummary) -> NSAlert {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = summary.dialogMessage
    alert.informativeText = String(
      localized: """
        Deny if you don't recognize this request. Allowing for 15 minutes skips this prompt for \
        \(summary.agentDescription) until then.
        """
    )
    alert.addButton(withTitle: String(localized: "Allow"))
    alert.addButton(withTitle: String(localized: "Allow for 15 Minutes"))
    alert.addButton(withTitle: String(localized: "Deny"))
    return alert
  }

  private nonisolated static func decision(for response: NSApplication.ModalResponse) -> ApprovalDecision {
    switch response {
    case .alertFirstButtonReturn: return .allowOnce
    case .alertSecondButtonReturn: return .allowFor15Minutes
    default: return .deny
    }
  }

  private func resolve(_ id: UUID, decision: ApprovalDecision) async {
    _ = try? await agentClient.resolveApproval(id: id, decision: decision)
  }
}

extension PendingApprovalSummary {
  /// The dialog's headline, e.g. "claude wants to read the password for \"GitHub\"." — combining
  /// `agentDescription`, `operationDescription`, and (if resolved) `itemTitle`, per
  /// `AgentServer.operationDescription(for:)`'s doc comment. Doesn't include a "(via lilpass)"
  /// clause, unlike that comment's illustrative example: the immediate caller (`lilpass`, an MCP
  /// server, etc.) isn't part of the wire payload — only the resolved *top-level* agent identity is
  /// (see `AgentGrantIdentity`) — so there's nothing here to render that clause from.
  fileprivate var dialogMessage: String {
    if let itemTitle {
      return String(localized: "\(agentDescription) \(operationDescription) \"\(itemTitle)\".")
    }
    return String(localized: "\(agentDescription) \(operationDescription).")
  }
}
