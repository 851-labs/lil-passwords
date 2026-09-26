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

  // 851-2465: a real, signed-and-installed-to-`/Applications` smoke test found `.notFound`
  // reported by `SMAppService.status` for a build whose plist was present, valid, and correctly
  // sealed in the code signature — simply because `servicemanagementd` had never recorded this
  // service before. Calling `register()` anyway succeeded immediately. So `.notFound` is now
  // treated like `.notRegistered`: attempt `register()` rather than reporting a false negative.

  @Test func notFoundRegistersAndReportsRegisteredWhenApprovalIsntNeeded() {
    let registrar = FakeRegistrar(status: .notFound)
    registrar.statusAfterRegister = .enabled
    let outcome = HelperAgentRegistrar.registerIfNeeded(using: registrar)
    #expect(outcome == .registered)
    #expect(registrar.registerCallCount == 1)
  }

  @Test func notFoundRegistersAndReportsRequiresApprovalWhenItLandsThatWay() {
    let registrar = FakeRegistrar(status: .notFound)
    registrar.statusAfterRegister = .requiresApproval
    let outcome = HelperAgentRegistrar.registerIfNeeded(using: registrar)
    #expect(outcome == .requiresApproval)
    #expect(registrar.registerCallCount == 1)
  }

  @Test func notFoundReportsRegistrationFailedWhenRegisterThrows() {
    let registrar = FakeRegistrar(status: .notFound)
    registrar.registerError = FakeRegistrar.RegisterFailure()
    let outcome = HelperAgentRegistrar.registerIfNeeded(using: registrar)
    #expect(outcome == .registrationFailed(message: "\(FakeRegistrar.RegisterFailure())"))
    #expect(registrar.registerCallCount == 1)
  }

  @Test func notFoundStillReportsNotFoundWhenRegisterSucceedsButStatusDoesntChange() {
    // The genuine "broken build" case this status exists for: `register()` doesn't throw, but the
    // plist truly isn't found, so `status` reads `.notFound` again immediately afterward too.
    let registrar = FakeRegistrar(status: .notFound)
    registrar.statusAfterRegister = .notFound
    let outcome = HelperAgentRegistrar.registerIfNeeded(using: registrar)
    #expect(outcome == .notFound)
    #expect(registrar.registerCallCount == 1)
  }
}
