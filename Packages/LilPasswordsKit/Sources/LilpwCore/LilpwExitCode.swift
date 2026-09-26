import LilPasswordsKit

/// `lilpw`'s stable exit codes, per 851-2430: a script driving `lilpw` (or an agent shelling out to
/// it) can switch on these without parsing stderr text, the same way `AgentError` lets in-process
/// Swift callers switch on a typed reason instead of a message.
///
/// These are `lilpw`'s own codes, distinct from ``AgentError``'s cases — `LilpwError.from(_:)` is
/// the single place that maps one to the other (plus the CLI-only failure modes, like a bad
/// `--field` value, that never reach `AgentServer` at all).
public enum LilpwExitCode: Int32, Sendable, Equatable {
  case ok = 0
  case generic = 1
  case usage = 2
  case locked = 3
  case agentAccessDisabled = 4
  case notFound = 5
  case ambiguous = 6
  case helperUnreachable = 7
}

/// The one error type every `LilpwCore` entry point throws: a stable exit code plus a message safe
/// to print to stderr.
///
/// Never wraps a secret in `message` — the same rule ``AgentError/internal(message:)`` documents,
/// since these messages come from the same places (a `VaultStoreError`'s description, an
/// `ItemReference` that failed to resolve) that already guarantee it.
public struct LilpwError: Error, Sendable, Equatable, CustomStringConvertible {
  public let exitCode: LilpwExitCode
  public let message: String

  public init(exitCode: LilpwExitCode, message: String) {
    self.exitCode = exitCode
    self.message = message
  }

  public var description: String { message }
}

extension LilpwError {
  /// Maps any error a `LilpwCore` entry point can throw (an `AgentClient.RequestError`, one of
  /// `LilpwCore`'s own validation errors, or something unexpected) to a stable exit code and a
  /// safe-to-print message.
  public static func from(_ error: Error) -> LilpwError {
    switch error {
    case let error as LilpwError:
      return error

    case let error as AgentClient.RequestError:
      switch error {
      case .connection(let connectionError):
        return LilpwError(exitCode: .helperUnreachable, message: connectionError.description)
      case .remote(let agentError):
        return from(agentError)
      }

    case let error as AgentError:
      return from(agentError: error)

    default:
      return LilpwError(exitCode: .generic, message: "\(error)")
    }
  }

  private static func from(agentError error: AgentError) -> LilpwError {
    switch error {
    case .locked:
      return LilpwError(exitCode: .locked, message: error.description)
    case .agentAccessDisabled:
      return LilpwError(exitCode: .agentAccessDisabled, message: error.description)
    case .notFound:
      return LilpwError(exitCode: .notFound, message: error.description)
    case .ambiguous:
      return LilpwError(exitCode: .ambiguous, message: error.description)
    case .unsupportedProtocolVersion, .internal, .callerNotAuthorized:
      return LilpwError(exitCode: .generic, message: error.description)
    }
  }
}
