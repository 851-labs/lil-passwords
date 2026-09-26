import Foundation

/// Fans out `VaultStoring.observeChanges()`'s "something changed" signal to every live
/// subscriber.
///
/// A tiny actor of its own (rather than a stored property of `VaultStore`/`InMemoryVaultStore`)
/// so a subscriber's `AsyncStream.Continuation.onTermination` — which the runtime can invoke on
/// an arbitrary thread when a subscriber's task is cancelled — has a safe, isolated place to hop
/// back into to remove itself, instead of touching the owning store's state directly from an
/// unstructured context.
actor VaultChangeHub {
  private var continuations: [Int: AsyncStream<Void>.Continuation] = [:]
  private var nextToken = 0

  func makeStream() -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let token = nextToken
    nextToken += 1
    continuations[token] = continuation

    continuation.onTermination = { [weak self] _ in
      guard let self else { return }
      Task { await self.remove(token) }
    }

    return stream
  }

  func notify() {
    for continuation in continuations.values {
      continuation.yield(())
    }
  }

  private func remove(_ token: Int) {
    continuations.removeValue(forKey: token)
  }
}
