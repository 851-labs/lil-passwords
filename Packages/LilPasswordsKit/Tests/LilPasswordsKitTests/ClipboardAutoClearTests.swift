import Foundation
import Testing

@testable import LilPasswordsKit

/// A fake pasteboard: just a mutable `changeCount` and a record of how many times `clear()` was
/// called, so tests can simulate "something else got copied" by bumping the counter mid-wait.
@MainActor
private final class FakeClipboardTarget: ClipboardTarget {
  var changeCount: Int
  private(set) var clearCallCount = 0

  init(changeCount: Int) {
    self.changeCount = changeCount
  }

  func clear() {
    clearCallCount += 1
  }
}

/// A fake clock whose `sleep(for:)` suspends until the test explicitly resumes it via
/// `advance()`, rather than actually waiting — so these tests are instant and deterministic
/// instead of racing a real 90-second timeout.
@MainActor
private final class FakeClipboardClock: ClipboardClock {
  private(set) var lastRequestedInterval: TimeInterval?
  private var continuation: CheckedContinuation<Void, Never>?

  func sleep(for seconds: TimeInterval) async {
    lastRequestedInterval = seconds
    await withCheckedContinuation { continuation = $0 }
  }

  /// Simulates `seconds` elapsing: resumes whatever `sleep(for:)` call is currently suspended.
  func advance() {
    continuation?.resume()
    continuation = nil
  }

  /// Spins until some call to `sleep(for:)` is actually suspended, so a test can safely mutate
  /// shared state (e.g. the fake target's `changeCount`) knowing it lands strictly before
  /// `advance()` lets `ClipboardAutoClear`'s post-wait comparison run — without depending on real
  /// wall-clock timing or assuming a fixed number of `Task.yield()` calls is enough.
  func waitUntilSleeping() async {
    while continuation == nil {
      await Task.yield()
    }
  }
}

@MainActor
@Suite struct ClipboardAutoClearTests {
  @Test func clearsAfterTheDelayWhenNothingElseWasCopied() async {
    let clock = FakeClipboardClock()
    let target = FakeClipboardTarget(changeCount: 5)
    let autoClear = ClipboardAutoClear(clock: clock)

    let task = Task {
      await autoClear.clearAfterDelay(90, target: target, changeCountAfterCopy: 5)
    }
    await clock.waitUntilSleeping()
    clock.advance()
    await task.value

    #expect(clock.lastRequestedInterval == 90)
    #expect(target.clearCallCount == 1)
  }

  @Test func doesNotClearIfSomethingElseWasCopiedDuringTheDelay() async {
    let clock = FakeClipboardClock()
    let target = FakeClipboardTarget(changeCount: 5)
    let autoClear = ClipboardAutoClear(clock: clock)

    let task = Task {
      await autoClear.clearAfterDelay(90, target: target, changeCountAfterCopy: 5)
    }
    await clock.waitUntilSleeping()
    target.changeCount = 6  // something else was copied before the timeout fired
    clock.advance()
    await task.value

    #expect(target.clearCallCount == 0)
  }

  @Test func doesNotWaitAtAllIfThePasteboardAlreadyChangedBeforeScheduling() async {
    let clock = FakeClipboardClock()
    let target = FakeClipboardTarget(changeCount: 5)
    let autoClear = ClipboardAutoClear(clock: clock)

    await autoClear.clearAfterDelay(90, target: target, changeCountAfterCopy: 4)

    #expect(clock.lastRequestedInterval == nil)
    #expect(target.clearCallCount == 0)
  }
}
