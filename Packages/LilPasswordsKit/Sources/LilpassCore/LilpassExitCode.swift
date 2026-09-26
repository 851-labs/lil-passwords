import LilPasswordsKit

/// `lilpass`'s stable exit codes, per 851-2430: a script driving `lilpass` (or an agent shelling out to
/// it) can switch on these without parsing stderr text, the same way `AgentError` lets in-process
/// Swift callers switch on a typed reason instead of a message.
///
/// These are `lilpass`'s own codes, distinct from ``AgentError``'s cases — `LilpassError.from(_:)` is
/// the single place that maps one to the other (plus the CLI-only failure modes, like a bad
/// `--field` value, that never reach `AgentServer` at all).
public enum LilpassExitCode: Int32, Sendable, Equatable {
  case ok = 0
  case generic = 1
  case usage = 2
  case locked = 3
  case agentAccessDisabled = 4
  case notFound = 5
  case ambiguous = 6
  case helperUnreachable = 7
}

/// The one error type every `LilpassCore` entry point throws: a stable exit code plus a message safe
/// to print to stderr.
///
/// Never wraps a secret in `message` — the same rule ``AgentError/internal(message:)`` documents,
/// since these messages come from the same places (a `VaultStoreError`'s description, an
/// `ItemReference` that failed to resolve) that already guarantee it.
public struct LilpassError: Error, Sendable, Equatable, CustomStringConvertible {
  public let exitCode: LilpassExitCode
  public let message: String

  public init(exitCode: LilpassExitCode, message: String) {
    self.exitCode = exitCode
    self.message = message
  }

  public var description: String { message }
}

extension LilpassError {
  /// Maps any error a `LilpassCore` entry point can throw (an `AgentClient.RequestError`, one of
  /// `LilpassCore`'s own validation errors, or something unexpected) to a stable exit code and a
  /// safe-to-print message.
  public static func from(_ error: Error) -> LilpassError {
    switch error {
    case let error as LilpassError:
      return error

    case let error as AgentClient.RequestError:
      switch error {
      case .connection(let connectionError):
        return LilpassError(exitCode: .helperUnreachable, message: connectionError.description)
      case .remote(let agentError):
        return from(agentError)
      }

    case let error as AgentError:
      return from(agentError: error)

    default:
      return LilpassError(exitCode: .generic, message: "\(error)")
    }
  }

  private static func from(agentError error: AgentError) -> LilpassError {
    switch error {
    case .locked:
      return LilpassError(exitCode: .locked, message: error.description)
    case .agentAccessDisabled:
      return LilpassError(exitCode: .agentAccessDisabled, message: error.description)
    case .notFound:
      return LilpassError(exitCode: .notFound, message: error.description)
    case .ambiguous:
      return LilpassError(exitCode: .ambiguous, message: error.description)
    case .unsupportedProtocolVersion, .internal, .callerNotAuthorized:
      return LilpassError(exitCode: .generic, message: error.description)
    }
  }
}
