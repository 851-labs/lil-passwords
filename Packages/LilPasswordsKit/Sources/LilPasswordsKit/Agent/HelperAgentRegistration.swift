import Foundation
// `SMAppService` predates Swift concurrency's `Sendable` audits and isn't marked `Sendable`,
// even though every method/property used below (`status`, `register()`,
// `openSystemSettingsLoginItems()`) is documented as safe to call from any thread — there's no
// mutable state of ours ever shared across it. `@preconcurrency` downgrades the resulting error
// to a warning rather than papering over it with `@unchecked Sendable` on our own type for a
// framework limitation, not an actual data race.
@preconcurrency import ServiceManagement

/// Whether `LilPasswordsAgent` is registered with launchd as a login item, mirroring
/// `SMAppService.Status` (macOS 13+) but as our own type so `HelperAgentRegistrar`'s decision
/// logic (below) is testable without a real `SMAppService` — the same seam pattern
/// `VaultAuthenticating`/`VaultAgentConnecting` already use for `LAContext`/`AgentClient`.
public enum HelperAgentStatus: Sendable, Equatable {
  /// Never registered (fresh install), or unregistered since (e.g. the user removed it from
  /// Login Items in System Settings).
  case notRegistered
  /// Registered and approved — launchd will activate `LilPasswordsAgent` on the first XPC
  /// connection to `AgentXPC.machServiceName`, exactly as `Agent/Support/com.851labs.lilpasswords.agent.plist`
  /// describes.
  case enabled
  /// Registered, but the user hasn't approved it in System Settings → General → Login Items yet
  /// — until they do, launchd won't actually run it, so every `AgentClient` call would fail.
  case requiresApproval
  /// `SMAppService` couldn't find this agent's plist in the app bundle at all. Shouldn't happen
  /// in a correctly-built app (see `project.yml`'s embed of
  /// `Agent/Support/com.851labs.lilpasswords.agent.plist` at `Contents/Library/LaunchAgents`) —
  /// this exists so a broken build reports something diagnosable instead of a confusing XPC
  /// connection failure three steps later.
  case notFound
}

/// Registers (or checks the registration of) `LilPasswordsAgent` as a launchd login item —
/// see `Agent/Support/com.851labs.lilpasswords.agent.plist`'s documentation for why `BundleProgram`
/// makes this specifically an `SMAppService.agent(plistName:)`, not `.daemon`/`.loginItem`.
///
/// A protocol (rather than `HelperAgentRegistrar` calling `SMAppService` directly) so 851-2411's
/// "register on launch, handle `.requiresApproval`" decision logic is unit-testable without
/// actually registering a login item every time the test suite runs.
public protocol HelperAgentRegistering: Sendable {
  /// `SMAppService.status`: a live, synchronous query against `servicemanagementd`, not a cached
  /// value — safe to call again immediately after `register()` to see whether it landed as
  /// `.enabled` or `.requiresApproval`.
  var status: HelperAgentStatus { get }

  /// `SMAppService.register()`. Throws if registration itself fails (not for the
  /// `.requiresApproval` case, which is a *successful* registration still awaiting the user's
  /// approval — check `status` again after this returns to tell the two apart).
  func register() throws

  /// `SMAppService.openSystemSettingsLoginItems()`: opens System Settings directly to
  /// General → Login Items & Extensions, the same screen the `.requiresApproval` explanation
  /// sheet's button sends the user to.
  func openSystemSettingsLoginItems()
}

/// The real conformer, wrapping the actual `SMAppService.agent(plistName:)` for
/// `com.851labs.lilpasswords.agent.plist`.
public struct SMAppServiceHelperAgent: HelperAgentRegistering {
  private let service: SMAppService

  public init(plistName: String = "com.851labs.lilpasswords.agent.plist") {
    service = SMAppService.agent(plistName: plistName)
  }

  public var status: HelperAgentStatus {
    switch service.status {
    case .notRegistered: return .notRegistered
    case .enabled: return .enabled
    case .requiresApproval: return .requiresApproval
    case .notFound: return .notFound
    @unknown default: return .notFound
    }
  }

  public func register() throws {
    try service.register()
  }

  public func openSystemSettingsLoginItems() {
    SMAppService.openSystemSettingsLoginItems()
  }
}

/// What the app should do after `HelperAgentRegistrar.registerIfNeeded(using:)` runs.
public enum HelperAgentRegistrationOutcome: Sendable, Equatable {
  /// Already registered and approved — nothing to do.
  case alreadyEnabled
  /// Was unregistered; `register()` was called and it's already approved (or doesn't need
  /// approval — e.g. a signed, notarized build the user has trusted before).
  case registered
  /// Registered (just now, or already) but still awaiting the user's approval in System
  /// Settings → Login Items. The app should explain this and offer to open that screen.
  case requiresApproval
  /// `SMAppService` couldn't find the agent's plist in the bundle. Log this clearly — see
  /// `HelperAgentStatus.notFound`.
  case notFound
  /// `register()` itself threw.
  case registrationFailed(message: String)
}

/// 851-2411: on every app launch, make sure `LilPasswordsAgent` is actually registered with
/// launchd — without this, first run and every unlock attempt fail, since
/// `NSXPCConnection(machServiceName:)` has nothing to resolve against.
public enum HelperAgentRegistrar {
  /// Registration is idempotent and cheap — `status` alone doesn't launch anything, and
  /// `register()` on an already-registered service is simply skipped below — so this can safely
  /// run unconditionally on every launch rather than only once ever (e.g. after the user
  /// re-approves it, or removes and re-adds it, in Login Items).
  public static func registerIfNeeded(using registrar: any HelperAgentRegistering) -> HelperAgentRegistrationOutcome {
    switch registrar.status {
    case .enabled:
      return .alreadyEnabled

    case .requiresApproval:
      return .requiresApproval

    case .notFound:
      return .notFound

    case .notRegistered:
      do {
        try registrar.register()
      } catch {
        return .registrationFailed(message: "\(error)")
      }
      // `register()` on a never-registered service can land as either `.enabled` or
      // `.requiresApproval` depending on whether the user has approved this app's login items
      // before — re-check rather than assume, since only `status` (not `register()`'s return
      // value) tells the two apart.
      switch registrar.status {
      case .requiresApproval:
        return .requiresApproval
      default:
        return .registered
      }
    }
  }
}
