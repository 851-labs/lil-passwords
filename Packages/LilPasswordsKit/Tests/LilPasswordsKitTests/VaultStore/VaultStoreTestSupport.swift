import Foundation

@testable import LilPasswordsKit

func makeSamplePasswordItem(
  title: String = "Example",
  usernames: [String] = ["alice"],
  password: String = "hunter2",
  websites: [URL] = [URL(string: "https://example.com/login")!]
) -> PasswordItem {
  PasswordItem(title: title, usernames: usernames, password: password, websites: websites)
}

/// A fresh, empty temporary directory this test can use as a database's home. Every call gets
/// its own directory (rather than one shared scratch dir) so parallel tests never race on the
/// same SQLite file.
func makeTempDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

/// A Darwin notification name unique to one test. `VaultStore` defaults to the real,
/// project-wide name, which is exactly what production wants but exactly what parallel tests
/// don't: two tests sharing that system-wide, unscoped channel could observe each other's writes.
func uniqueDarwinNotificationName() -> String {
  "com.851labs.lilpasswords.tests.\(UUID().uuidString)"
}

/// A one-shot, actor-isolated `Bool` result. `fulfill` is idempotent — only the first call has any
/// effect — and `wait()` suspends until some call to `fulfill` happens.
private actor BoolSignal {
  private var result: Bool?
  private var continuation: CheckedContinuation<Bool, Never>?

  func fulfill(_ value: Bool) {
    guard result == nil else { return }
    result = value
    continuation?.resume(returning: value)
    continuation = nil
  }

  func wait() async -> Bool {
    if let result { return result }
    return await withCheckedContinuation { continuation = $0 }
  }
}

/// Waits for `stream` to produce at least one element, up to `timeout`. Returns `true` if it did,
/// `false` on timeout.
///
/// Deliberately not just `await iterator.next() != nil`: a plain wait would hang this entire test
/// suite forever if change observation ever regressed to not firing (`AsyncStream.next()` isn't
/// guaranteed to observe this task's own cancellation), which is exactly the failure mode these
/// change-observation tests exist to catch. Racing against an unconditional timeout means a
/// regression here shows up as one failed test, not a stuck CI job.
func waitForFirstElement<T: Sendable>(of stream: AsyncStream<T>, timeout: Duration = .seconds(5)) async -> Bool {
  let signal = BoolSignal()

  Task.detached {
    var iterator = stream.makeAsyncIterator()
    let value = await iterator.next()
    await signal.fulfill(value != nil)
  }

  Task.detached {
    try? await Task.sleep(for: timeout)
    await signal.fulfill(false)
  }

  return await signal.wait()
}
