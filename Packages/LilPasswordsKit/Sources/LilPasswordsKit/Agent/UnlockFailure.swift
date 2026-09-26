import Foundation

/// A `LockCoordinator` failure, translated into copy that's safe to show directly on the lock
/// screen — never a raw `"\(error)"` interpolation of an XPC/Swift error.
///
/// 851-2465: an unsigned dev build launched from `build/` (rather than a real,
/// `/Applications`-installed one) showed `AgentClient.ConnectionError.invalidated`'s raw reason
/// text — "the connection to LilPasswordsAgent was invalidated (Couldn't communicate with a
/// helper application.)" — directly on the lock screen, in red. `describing(_:)` below is the
/// fix: every `AgentClient.RequestError.connection` case becomes the same short, actionable
/// sentence regardless of the underlying reason, and `isHelperUnreachable` tells
/// `MainWindowController` (App target) when a "Try Again" affordance — and, if the helper simply
/// isn't approved yet, a Login Items hint — make sense.
///
/// Mirrors `LilpassError.from(_:)` in `LilpassCore`, which does the identical mapping for
/// `lilpass`/`lilpass mcp`'s stderr output; this is the app UI's equivalent. Kept in
/// `LilPasswordsKit` proper (not `LilpassCore`) since the app target links this module, not that
/// one — see `project.yml`.
public struct UnlockFailure: Sendable, Equatable {
  /// Safe to show verbatim under the lock screen's subtitle.
  public let message: String

  /// `true` for any `AgentClient.RequestError.connection` case — the helper couldn't be reached
  /// at all, so retrying (and, if it's simply unapproved, opening Login Items) are meaningful next
  /// steps. `false` for a `.remote(AgentError)` failure (the helper answered, just with a "no" —
  /// e.g. agent access is disabled) or anything else (a cancelled `LAContext` prompt): those
  /// already carry their own specific, hand-written description, and no "Try Again" affordance
  /// applies since the helper itself is reachable.
  public let isHelperUnreachable: Bool

  public init(message: String, isHelperUnreachable: Bool) {
    self.message = message
    self.isHelperUnreachable = isHelperUnreachable
  }

  /// Maps anything `VaultAgentConnecting` can throw to an `UnlockFailure`. Every
  /// `AgentClient.RequestError.connection` case collapses to the same friendly sentence — the
  /// specific reason (crashed, killed, failed the code-signing check, a bad reply) is
  /// developer-diagnostic detail, not something a user can act on differently case by case.
  /// `.remote(AgentError)` passes through `AgentError.description`, which is already
  /// hand-written and friendly for every case. Anything that isn't an `AgentClient.RequestError`
  /// at all (e.g. a cancelled `LAContext` evaluation) falls back to its own description unchanged
  /// — out of scope for 851-2465, which is specifically about the raw XPC connection string.
  public static func describing(_ error: Error) -> UnlockFailure {
    guard let requestError = error as? AgentClient.RequestError else {
      return UnlockFailure(message: "\(error)", isHelperUnreachable: false)
    }
    switch requestError {
    case .connection:
      return UnlockFailure(
        message: "Couldn't reach \(LilPasswordsKit.productName)' background helper.",
        isHelperUnreachable: true
      )
    case .remote(let agentError):
      return UnlockFailure(message: agentError.description, isHelperUnreachable: false)
    }
  }
}
