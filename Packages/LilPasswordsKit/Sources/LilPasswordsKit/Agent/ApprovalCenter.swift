import AppKit
import CoreFoundation
import Foundation

/// How one 851-2445 "ask every time" approval request was ultimately resolved — recorded on the
/// access log (`AccessEvent.approvalOutcome`) alongside whatever the underlying vault operation
/// did or didn't do.
public enum ApprovalOutcome: Sendable, Codable, Equatable {
  /// The caller's top-level agent already held an unexpired "allow for 15 minutes" grant; no
  /// prompt was shown for this specific request.
  case grantedByPriorGrant
  /// The person pressed Allow for just this one request.
  case grantedOnce
  /// The person pressed "Allow for 15 minutes"; a grant was recorded for this request's
  /// `AgentGrantIdentity`.
  case grantedFor15Minutes
  /// The person pressed Deny, or nobody responded within the timeout — indistinguishable by
  /// design; see ``AgentError/approvalDeniedOrTimedOut``.
  case deniedOrTimedOut
}

/// Launches the app when the helper needs to show an 851-2445 approval prompt and the app might
/// not currently be running. **Seam**: production wiring (`Agent/Sources/main.swift`) supplies
/// ``NSWorkspaceApprovalAppLauncher``; tests supply a no-op or call-counting double.
///
/// Deliberately cheap and idempotent to call even when the app is already running: bringing it to
/// the foreground is the desired outcome of a Touch ID-style prompt either way (see
/// docs/adr/0005-scoped-agent-access.md's "Approval flow" section for why this avoids needing any
/// "is a connection already open" tracking).
public protocol ApprovalAppLaunching: Sendable {
  func launchAppIfNeeded()
}

/// The production ``ApprovalAppLaunching``: asks `NSWorkspace` to open the app by bundle
/// identifier, the same identifier `AgentConnectionSecurity.PeerIdentifier.app` names.
public struct NSWorkspaceApprovalAppLauncher: ApprovalAppLaunching {
  private let appBundleIdentifier: String

  public init(appBundleIdentifier: String = AgentConnectionSecurity.PeerIdentifier.app.rawValue) {
    self.appBundleIdentifier = appBundleIdentifier
  }

  public func launchAppIfNeeded() {
    guard
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleIdentifier)
    else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
  }
}

/// Does nothing. Used by tests that don't care whether/how the app gets launched.
public struct NoOpApprovalAppLauncher: ApprovalAppLaunching {
  public init() {}
  public func launchAppIfNeeded() {}
}

/// The 851-2445 in-memory approval queue: parks a vault operation on a `CheckedContinuation` while
/// ``AgentAccessScope/askEveryTime`` is active, wakes the app (Darwin notification, and a
/// best-effort app launch), and resumes the parked operation once the app answers via
/// ``resolve(id:decision:)`` or the timeout fires — whichever happens first.
///
/// An actor, not a plain class: `AgentServer` calls ``requestApproval(for:agentDescription:itemTitle:operationDescription:timeout:)``
/// and suspends at the `await`, but that suspension never blocks this actor as a whole — actors are
/// reentrant across `await` — so the app's own, concurrent ``pendingApprovals()``/``resolve(id:decision:)``
/// calls (arriving as ordinary forward XPC requests on the very same `AgentServer`) are serviced
/// while the original request is still parked. See docs/adr/0005-scoped-agent-access.md's
/// "Approval flow" section for the full design, including why this reuses the existing XPC channel
/// instead of a new reverse connection.
public actor ApprovalCenter {
  private struct Pending {
    let continuation: CheckedContinuation<ApprovalOutcome, Never>
    let identity: AgentGrantIdentity
  }

  private var pending: [UUID: Pending] = [:]
  private var summaries: [UUID: PendingApprovalSummary] = [:]
  private var grants: [AgentGrantIdentity: Date] = [:]

  private let now: @Sendable () -> Date
  private let appLauncher: any ApprovalAppLaunching

  /// - Parameters:
  ///   - now: Overridable clock, purely for ``ApprovalCenterTests``' grant-expiry coverage —
  ///     production always uses the default, real `Date()`.
  ///   - appLauncher: Where a pending approval's "launch the app if it isn't running" step goes.
  ///     Defaults to ``NoOpApprovalAppLauncher`` so existing/test call sites that don't care don't
  ///     need updating; production wiring (`Agent/Sources/main.swift`) always passes
  ///     ``NSWorkspaceApprovalAppLauncher`` explicitly.
  public init(
    now: @escaping @Sendable () -> Date = Date.init,
    appLauncher: any ApprovalAppLaunching = NoOpApprovalAppLauncher()
  ) {
    self.now = now
    self.appLauncher = appLauncher
  }

  /// Asks for a decision on one vault operation. Returns immediately (``ApprovalOutcome/grantedByPriorGrant``)
  /// if `identity` already holds an unexpired "allow for 15 minutes" grant; otherwise parks the
  /// caller until the app calls ``resolve(id:decision:)`` or `timeout` elapses, whichever is first.
  ///
  /// `timeout` defaults to the ticket's ~60 seconds in production; tests pass a much shorter
  /// `Duration` so the timeout path doesn't actually take a minute to exercise.
  public func requestApproval(
    for identity: AgentGrantIdentity,
    agentDescription: String,
    itemTitle: String?,
    operationDescription: String,
    timeout: Duration = .seconds(60)
  ) async -> ApprovalOutcome {
    if let expiry = grants[identity], expiry > now() {
      return .grantedByPriorGrant
    }
    // An expired grant is just dead weight in the dictionary from here on — clear it so a stale
    // entry doesn't linger forever for an agent identity that never reconnects.
    grants[identity] = nil

    let id = UUID()
    let summary = PendingApprovalSummary(
      id: id,
      requestedAt: now(),
      agentDescription: agentDescription,
      itemTitle: itemTitle,
      operationDescription: operationDescription
    )

    appLauncher.launchAppIfNeeded()
    AgentApprovalNotifications.post()

    return await withCheckedContinuation { continuation in
      pending[id] = Pending(continuation: continuation, identity: identity)
      summaries[id] = summary
      Task { [weak self] in
        try? await Task.sleep(for: timeout)
        await self?.timeoutIfStillPending(id)
      }
    }
  }

  /// Every request currently parked awaiting a decision, oldest first — what
  /// `AgentRequest.pendingApprovals` answers with.
  public func pendingApprovals() -> [PendingApprovalSummary] {
    summaries.values.sorted { $0.requestedAt < $1.requestedAt }
  }

  /// Answers the pending approval identified by `id`. Returns `false` (a no-op) if `id` isn't
  /// currently pending — already resolved, already timed out, or never existed — so a duplicate or
  /// late `.resolveApproval` from the app can't crash or double-resume a continuation.
  @discardableResult
  public func resolve(id: UUID, decision: ApprovalDecision) -> Bool {
    guard let entry = pending.removeValue(forKey: id) else { return false }
    summaries.removeValue(forKey: id)

    switch decision {
    case .allowOnce:
      entry.continuation.resume(returning: .grantedOnce)
    case .allowFor15Minutes:
      grants[entry.identity] = now().addingTimeInterval(15 * 60)
      entry.continuation.resume(returning: .grantedFor15Minutes)
    case .deny:
      entry.continuation.resume(returning: .deniedOrTimedOut)
    }
    return true
  }

  private func timeoutIfStillPending(_ id: UUID) {
    guard let entry = pending.removeValue(forKey: id) else { return }
    summaries.removeValue(forKey: id)
    entry.continuation.resume(returning: .deniedOrTimedOut)
  }
}

/// Cross-process notification that a new 851-2445 approval request is waiting — posted by
/// `ApprovalCenter` whenever it parks a request, observed by the app so it can immediately fetch
/// `AgentRequest.pendingApprovals` and show the Touch ID-gated dialog, instead of polling.
///
/// The exact same shape as ``LockStateNotifications``/``LockStateObserver`` (Darwin notifications,
/// deliberately payload-less — the app fetches the actual summary over XPC, this is only a wake-up
/// signal); kept as a separate name/type rather than reusing `LockStateNotifications` since the two
/// signal unrelated things and a future change to one shouldn't risk the other.
public enum AgentApprovalNotifications {
  public static let approvalPending = "com.851labs.lilpasswords.agentApprovalPending"

  public static func post() {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(approvalPending as CFString),
      nil,
      nil,
      true
    )
  }
}

/// Observes ``AgentApprovalNotifications/approvalPending`` for as long as this instance is alive —
/// the public counterpart to ``LockStateObserver``, same `CFNotificationCenter` C callback
/// trampoline pattern.
public final class AgentApprovalObserver {
  private let handler: () -> Void

  public init(handler: @escaping () -> Void) {
    self.handler = handler

    let observer = Unmanaged.passUnretained(self).toOpaque()
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      observer,
      { _, observer, _, _, _ in
        guard let observer else { return }
        Unmanaged<AgentApprovalObserver>.fromOpaque(observer).takeUnretainedValue().handler()
      },
      AgentApprovalNotifications.approvalPending as CFString,
      nil,
      .deliverImmediately
    )
  }

  deinit {
    CFNotificationCenterRemoveObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque(),
      CFNotificationName(AgentApprovalNotifications.approvalPending as CFString),
      nil
    )
  }
}
