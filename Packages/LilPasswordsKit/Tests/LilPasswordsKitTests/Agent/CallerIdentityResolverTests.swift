import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct CallerIdentityResolverTests {
  @Test func resolvingTheCurrentProcessFindsItsOwnPathAndAParentProcessName() {
    let identity = CallerIdentityResolver.resolve(pid: ProcessInfo.processInfo.processIdentifier)

    #expect(identity.pid == ProcessInfo.processInfo.processIdentifier)
    // The test binary is a real, running executable, so `proc_pidpath` should resolve it.
    #expect(identity.processPath != nil)
    #expect(identity.processPath?.isEmpty == false)
    // Every process except pid 1 has a parent; the test runner is never pid 1.
    #expect(identity.parentProcessName != nil)
  }

  @Test func resolvingAnImplausiblePidFailsGracefullyInsteadOfCrashing() {
    // pid_t is a 32-bit signed integer; this value is picked to almost certainly not correspond
    // to any running process, without being a sentinel like -1 that some libproc calls special-case.
    let identity = CallerIdentityResolver.resolve(pid: pid_t.max)

    #expect(identity.pid == pid_t.max)
    #expect(identity.processPath == nil)
    #expect(identity.parentProcessName == nil)
  }
}
