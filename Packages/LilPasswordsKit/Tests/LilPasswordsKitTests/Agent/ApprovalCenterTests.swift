import Foundation
import Testing

@testable import LilPasswordsKit

/// A mutable "current time" a test can advance between calls, mirroring `AccessLogStoreTests`'
/// own `MutableClock` — plain `var` captures aren't allowed in the `@Sendable` `now` closure
/// `ApprovalCenter` takes, so this boxes one behind a lock instead.
private final class MutableClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date

  init(_ date: Date) { self.date = date }

  func advance(by interval: TimeInterval) {
    lock.lock()
    date = date.addingTimeInterval(interval)
    lock.unlock()
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return date
  }
}

/// Counts how many times `launchAppIfNeeded()` was called, so tests can confirm `ApprovalCenter`
/// only launches the app for a genuinely new pending request — never for one already covered by a
/// prior grant.
private final class CountingAppLauncher: ApprovalAppLaunching, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var callCount = 0

  func launchAppIfNeeded() {
    lock.lock()
    callCount += 1
    lock.unlock()
  }
}

private let claudeIdentity = AgentGrantIdentity(executablePath: "/usr/local/bin/claude", codeSigningIdentifier: nil)

@Suite struct ApprovalCenterTests {
  @Test func pendingApprovalsListsAParkedRequestUntilItsResolved() async throws {
    let center = ApprovalCenter()

    async let outcome = center.requestApproval(
      for: claudeIdentity,
      agentDescription: "claude",
      itemTitle: "GitHub",
      operationDescription: "wants to read the password for",
      timeout: .seconds(10)
    )

    let pending = try await waitForPending(center)
    #expect(pending.count == 1)
    #expect(pending[0].agentDescription == "claude")
    #expect(pending[0].itemTitle == "GitHub")

    let resolved = await center.resolve(id: pending[0].id, decision: .allowOnce)
    #expect(resolved)
    #expect(await outcome == .grantedOnce)

    let afterResolution = await center.pendingApprovals()
    #expect(afterResolution.isEmpty)
  }

  @Test func resolveReturnsFalseForAnUnknownOrAlreadyResolvedId() async throws {
    let center = ApprovalCenter()
    #expect(await center.resolve(id: UUID(), decision: .deny) == false)
  }

  @Test func denyResolvesTheOutcomeToDeniedOrTimedOut() async throws {
    let center = ApprovalCenter()

    async let outcome = center.requestApproval(
      for: claudeIdentity,
      agentDescription: "claude",
      itemTitle: nil,
      operationDescription: "wants to list your passwords",
      timeout: .seconds(10)
    )

    let pending = try await waitForPending(center)
    _ = await center.resolve(id: pending[0].id, decision: .deny)
    #expect(await outcome == .deniedOrTimedOut)
  }

  @Test func aRequestThatNobodyAnswersTimesOutAsDeniedOrTimedOut() async throws {
    let center = ApprovalCenter()
    let outcome = await center.requestApproval(
      for: claudeIdentity,
      agentDescription: "claude",
      itemTitle: nil,
      operationDescription: "wants to list your passwords",
      timeout: .milliseconds(20)
    )
    #expect(outcome == .deniedOrTimedOut)
    #expect(await center.pendingApprovals().isEmpty)
  }

  /// The 851-2445 "allow for 15 minutes" grant: once given, a *second* request from the same
  /// `AgentGrantIdentity` is answered immediately with `.grantedByPriorGrant` — no new prompt, no
  /// new app launch — as long as the grant hasn't expired yet.
  @Test func allowFor15MinutesGrantsSubsequentRequestsFromTheSameIdentityWithoutReprompting() async throws {
    let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
    let launcher = CountingAppLauncher()
    let center = ApprovalCenter(now: clock.now, appLauncher: launcher)

    async let firstOutcome = center.requestApproval(
      for: claudeIdentity,
      agentDescription: "claude",
      itemTitle: "GitHub",
      operationDescription: "wants to read the password for",
      timeout: .seconds(10)
    )
    let pending = try await waitForPending(center)
    _ = await center.resolve(id: pending[0].id, decision: .allowFor15Minutes)
    #expect(await firstOutcome == .grantedFor15Minutes)
    #expect(launcher.callCount == 1)

    clock.advance(by: 5 * 60)  // still well within the 15-minute grant

    let secondOutcome = await center.requestApproval(
      for: claudeIdentity,
      agentDescription: "claude",
      itemTitle: "Mail",
      operationDescription: "wants to read the password for",
      timeout: .seconds(10)
    )
    #expect(secondOutcome == .grantedByPriorGrant)
    // No new prompt was ever shown for the second request, so the app was never launched for it.
    #expect(launcher.callCount == 1)
    #expect(await center.pendingApprovals().isEmpty)
  }

  /// Grant expiry: once 15 minutes have actually elapsed, a subsequent request from the same
  /// identity prompts again from scratch rather than reusing the stale grant.
  @Test func aGrantExpiresAfter15MinutesAndTheNextRequestPromptsAgain() async throws {
    let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
    let launcher = CountingAppLauncher()
    let center = ApprovalCenter(now: clock.now, appLauncher: launcher)

    async let firstOutcome = center.requestApproval(
      for: claudeIdentity,
      agentDescription: "claude",
      itemTitle: "GitHub",
      operationDescription: "wants to read the password for",
      timeout: .seconds(10)
    )
    let firstPending = try await waitForPending(center)
    _ = await center.resolve(id: firstPending[0].id, decision: .allowFor15Minutes)
    #expect(await firstOutcome == .grantedFor15Minutes)

    clock.advance(by: 15 * 60 + 1)  // just past the grant's expiry

    async let secondOutcome = center.requestApproval(
      for: claudeIdentity,
      agentDescription: "claude",
      itemTitle: "Mail",
      operationDescription: "wants to read the password for",
      timeout: .seconds(10)
    )
    let secondPending = try await waitForPending(center)
    #expect(secondPending.count == 1)
    #expect(launcher.callCount == 2)  // prompted again — the expired grant wasn't reused

    _ = await center.resolve(id: secondPending[0].id, decision: .allowOnce)
    #expect(await secondOutcome == .grantedOnce)
  }

  /// A grant is scoped to its `AgentGrantIdentity` — a different top-level agent gets its own
  /// prompt even while another identity's grant is still active.
  @Test func aGrantForOneIdentityDoesNotCoverADifferentIdentity() async throws {
    let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
    let center = ApprovalCenter(now: clock.now)
    let codexIdentity = AgentGrantIdentity(executablePath: "/usr/local/bin/codex", codeSigningIdentifier: nil)

    async let claudeOutcome = center.requestApproval(
      for: claudeIdentity,
      agentDescription: "claude",
      itemTitle: "GitHub",
      operationDescription: "wants to read the password for",
      timeout: .seconds(10)
    )
    let claudePending = try await waitForPending(center)
    _ = await center.resolve(id: claudePending[0].id, decision: .allowFor15Minutes)
    #expect(await claudeOutcome == .grantedFor15Minutes)

    async let codexOutcome = center.requestApproval(
      for: codexIdentity,
      agentDescription: "codex",
      itemTitle: "GitHub",
      operationDescription: "wants to read the password for",
      timeout: .seconds(10)
    )
    let codexPending = try await waitForPending(center)
    #expect(codexPending.count == 1)
    _ = await center.resolve(id: codexPending[0].id, decision: .deny)
    #expect(await codexOutcome == .deniedOrTimedOut)
  }

  @Test func noOpApprovalAppLauncherDoesNothingAndNeverThrows() {
    NoOpApprovalAppLauncher().launchAppIfNeeded()
  }

  /// Polls `pendingApprovals()` until the just-issued `requestApproval` call has actually parked —
  /// avoids a race between the `async let` starting and its `withCheckedContinuation` running.
  private func waitForPending(_ center: ApprovalCenter, maxAttempts: Int = 200) async throws
    -> [PendingApprovalSummary]
  {
    for _ in 0..<maxAttempts {
      let summaries = await center.pendingApprovals()
      if !summaries.isEmpty { return summaries }
      try await Task.sleep(for: .milliseconds(10))
    }
    return []
  }
}
