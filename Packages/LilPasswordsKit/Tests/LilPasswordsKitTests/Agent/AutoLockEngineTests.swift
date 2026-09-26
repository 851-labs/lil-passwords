import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct AutoLockEngineTests {
  /// A fake clock: tests set `idleInterval` directly instead of waiting on the wall clock, so
  /// idle-timeout behavior is deterministic and instant.
  private final class FakeClock: IdleTimeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var interval: TimeInterval

    init(idleInterval: TimeInterval) {
      self.interval = idleInterval
    }

    func idleInterval() -> TimeInterval {
      lock.lock()
      defer { lock.unlock() }
      return interval
    }

    func advance(to newInterval: TimeInterval) {
      lock.lock()
      interval = newInterval
      lock.unlock()
    }
  }

  private struct FixedPolicy: AutoLockPolicyProviding {
    var timeout: TimeInterval?
    func idleTimeout() async -> TimeInterval? { timeout }
  }

  @Test func doesNotLockBeforeTheIdleTimeoutElapses() async {
    let clock = FakeClock(idleInterval: 60)
    let engine = AutoLockEngine(policy: FixedPolicy(timeout: 5 * 60), idleProvider: clock)

    #expect(await engine.shouldLockForIdleTimeout() == false)
  }

  @Test func locksExactlyAtTheIdleTimeout() async {
    let clock = FakeClock(idleInterval: 5 * 60)
    let engine = AutoLockEngine(policy: FixedPolicy(timeout: 5 * 60), idleProvider: clock)

    #expect(await engine.shouldLockForIdleTimeout() == true)
  }

  @Test func locksOnceTheIdleIntervalExceedsTheTimeout() async {
    let clock = FakeClock(idleInterval: 0)
    let engine = AutoLockEngine(policy: FixedPolicy(timeout: 60), idleProvider: clock)

    #expect(await engine.shouldLockForIdleTimeout() == false)
    clock.advance(to: 61)
    #expect(await engine.shouldLockForIdleTimeout() == true)
  }

  @Test func neverLocksWhenTheIdleTimeoutPolicyIsDisabled() async {
    // `AutoLockPolicyProviding.idleTimeout() == nil` disables idle-timeout auto-lock entirely —
    // sleep and screen-lock triggers still apply, but those bypass `AutoLockEngine` altogether
    // (see `AutoLockTrigger`'s documentation), so there's nothing more for this type to do.
    let clock = FakeClock(idleInterval: .greatestFiniteMagnitude)
    let engine = AutoLockEngine(policy: FixedPolicy(timeout: nil), idleProvider: clock)

    #expect(await engine.shouldLockForIdleTimeout() == false)
  }

  @Test func usesTheDefaultFiveMinuteTimeoutWhenNoAppSettingsValueIsConfigured() async {
    // `FixedAutoLockPolicy` is what `Agent/Sources/main.swift` wires in until 851-2424 supplies a
    // real, `AppSettings`-backed policy — its default must match this ticket's own stated default
    // ("on idle timeout (AppSettings value if present, default 5 minutes)").
    let clock = FakeClock(idleInterval: 5 * 60 - 1)
    let defaultPolicyEngine = AutoLockEngine(policy: FixedAutoLockPolicy(), idleProvider: clock)
    #expect(await defaultPolicyEngine.shouldLockForIdleTimeout() == false)

    clock.advance(to: 5 * 60)
    #expect(await defaultPolicyEngine.shouldLockForIdleTimeout() == true)
  }
}
