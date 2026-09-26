import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct HelperAgentRegistrarTests {
  /// A fake `HelperAgentRegistering` whose status/`register()` behavior is scripted up front, so
  /// tests don't need a real `SMAppService` (which would actually register a login item with
  /// launchd every time the suite runs) to drive `HelperAgentRegistrar`'s decision logic.
  ///
  /// A plain lock-free class rather than an actor: every method here is synchronous, matching
  /// `HelperAgentRegistering`'s own synchronous shape (mirroring `SMAppService` itself, which is
  /// synchronous), so there's no isolation to gain from an actor — same reasoning
  /// `LockCoordinatorTests.FakeAgent` documents for why *it* isn't one either.
  private final class FakeRegistrar: HelperAgentRegistering, @unchecked Sendable {
    struct RegisterFailure: Error, Equatable {}

    var status: HelperAgentStatus
    /// If set, `register()` throws this instead of succeeding.
    var registerError: Error?
    /// What `status` should read as immediately after a successful `register()` call — simulates
    /// `SMAppService` landing on either `.enabled` or `.requiresApproval` depending on whether
    /// the user has approved this app's login items before.
    var statusAfterRegister: HelperAgentStatus = .enabled

    private(set) var registerCallCount = 0
    private(set) var openedSystemSettingsCallCount = 0

    init(status: HelperAgentStatus) {
      self.status = status
    }

    func register() throws {
      registerCallCount += 1
      if let registerError {
        throw registerError
      }
      status = statusAfterRegister
    }

    func openSystemSettingsLoginItems() {
      openedSystemSettingsCallCount += 1
    }
  }

  @Test func alreadyEnabledNeedsNoRegistration() {
    let registrar = FakeRegistrar(status: .enabled)
    let outcome = HelperAgentRegistrar.registerIfNeeded(using: registrar)
    #expect(outcome == .alreadyEnabled)
    #expect(registrar.registerCallCount == 0)
  }

  @Test func notRegisteredRegistersAndReportsRegisteredWhenApprovalIsntNeeded() {
    let registrar = FakeRegistrar(status: .notRegistered)
    registrar.statusAfterRegister = .enabled
    let outcome = HelperAgentRegistrar.registerIfNeeded(using: registrar)
    #expect(outcome == .registered)
    #expect(registrar.registerCallCount == 1)
  }

  @Test func notRegisteredRegistersAndReportsRequiresApprovalWhenItLandsThatWay() {
    let registrar = FakeRegistrar(status: .notRegistered)
    registrar.statusAfterRegister = .requiresApproval
    let outcome = HelperAgentRegistrar.registerIfNeeded(using: registrar)
    #expect(outcome == .requiresApproval)
    #expect(registrar.registerCallCount == 1)
  }

  @Test func notRegisteredReportsRegistrationFailedWhenRegisterThrows() {
    let registrar = FakeRegistrar(status: .notRegistered)
    registrar.registerError = FakeRegistrar.RegisterFailure()
    let outcome = HelperAgentRegistrar.registerIfNeeded(using: registrar)
    #expect(outcome == .registrationFailed(message: "\(FakeRegistrar.RegisterFailure())"))
    #expect(registrar.registerCallCount == 1)
  }

  @Test func alreadyRequiresApprovalIsReportedWithoutCallingRegisterAgain() {
    let registrar = FakeRegistrar(status: .requiresApproval)
    let outcome = HelperAgentRegistrar.registerIfNeeded(using: registrar)
    #expect(outcome == .requiresApproval)
    #expect(registrar.registerCallCount == 0)
  }

  @Test func notFoundIsReportedWithoutCallingRegister() {
    let registrar = FakeRegistrar(status: .notFound)
    let outcome = HelperAgentRegistrar.registerIfNeeded(using: registrar)
    #expect(outcome == .notFound)
    #expect(registrar.registerCallCount == 0)
  }
}
