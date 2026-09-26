import Foundation
import Security

/// Builds the code-signing requirement that validates the far side of an `NSXPCConnection`: the
/// helper checks that a connecting client is really the app or `lilpass`, and `AgentClient` checks
/// that it's really talking to the real helper, not a same-user process that squatted the Mach
/// service name before the real one started.
///
/// The requirement is built from **our own running process's team identifier**, read at runtime
/// via `SecCode`, rather than a hardcoded team id: the 851 Labs Apple Developer Program team
/// doesn't exist yet (851-2400), so every local build today signs with whichever developer's
/// personal team is configured in the gitignored `Config/Local.xcconfig` (see
/// docs/adr/0001-storage-and-process-model.md). Deriving the team id from the running binary
/// means this code works unchanged once a real Developer ID team replaces the personal one.
public enum AgentConnectionSecurity {
  /// Bundle identifiers of the processes allowed to hold either end of an agent connection,
  /// matching `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`.
  public enum PeerIdentifier: String, Sendable, CaseIterable {
    case app = "com.851labs.lilpasswords"
    case cli = "com.851labs.lilpasswords.cli"
    case agent = "com.851labs.lilpasswords.agent"
  }

  /// The validation `NSXPCListenerDelegate`/`AgentClient` should apply to a connection.
  public enum Requirement: Sendable, Equatable {
    /// A syntactically valid code-requirement string, ready for
    /// `NSXPCConnection.setCodeSigningRequirement(_:)`.
    case enforce(String)

    /// No team identifier could be determined for the running process, **and** this is a `DEBUG`
    /// build — an unsigned or ad-hoc-signed local/CI build (the default per `Config/Base.xcconfig`).
    /// Connections are accepted without code-signature validation.
    ///
    /// This is the documented local-dev fallback: an ad-hoc/unsigned build has no team identifier
    /// to build a requirement from, so enforcing one would make the agent reject every client on
    /// a machine without a configured `Config/Local.xcconfig` signing identity, including CI.
    /// Anyone who *does* configure a personal team there (see that file) gets real enforcement
    /// with no code change. **Never returned from a Release build** — see ``rejectAll(reason:)``.
    case developmentFallback(reason: String)

    /// No team identifier could be determined for the running process, and this is **not** a
    /// `DEBUG` build. Every connection must be refused rather than accepted unauthenticated: a
    /// Release build with no team identifier to validate against has no safe way to tell the real
    /// app/`lilpass` apart from any other process on the machine, and this helper holds the vault
    /// key once unlocked — silently running with `.developmentFallback`'s "accept anything"
    /// behavior in that configuration would let any local process read the vault through it.
    case rejectAll(reason: String)
  }

  /// Builds a `Requirement` accepting only peers whose code signature has our own running
  /// process's team identifier and one of `identifiers`' bundle identifiers.
  public static func requirement(acceptingPeers identifiers: [PeerIdentifier]) -> Requirement {
    requirement(acceptingPeers: identifiers, teamIdentifier: currentProcessTeamIdentifier(), isDebugBuild: isDebugBuild)
  }

  /// Whether this binary was compiled with `DEBUG` defined. A `static let` (rather than an inline
  /// `#if DEBUG` at each call site) so ``requirement(acceptingPeers:teamIdentifier:isDebugBuild:)``
  /// can take it as an ordinary parameter — tests exercise both the DEBUG and Release policy
  /// branches by passing `isDebugBuild` explicitly, regardless of which configuration the test
  /// binary itself was built with.
  static let isDebugBuild: Bool = {
    #if DEBUG
      return true
    #else
      return false
    #endif
  }()

  /// The `teamIdentifier`/`isDebugBuild`-parameterized half of ``requirement(acceptingPeers:)``,
  /// split out so tests can exercise the string-building, syntax-validation, and DEBUG-vs-Release
  /// fallback logic without depending on how the test binary itself happens to be signed or built.
  static func requirement(
    acceptingPeers identifiers: [PeerIdentifier],
    teamIdentifier: String?,
    isDebugBuild: Bool = isDebugBuild
  ) -> Requirement {
    guard let teamIdentifier else {
      return unauthenticatedFallback(
        reason: "no team identifier on the running process's own code signature (unsigned or ad-hoc build)",
        isDebugBuild: isDebugBuild
      )
    }
    let identifierClause = identifiers.map { "identifier \"\($0.rawValue)\"" }.joined(separator: " or ")
    let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\" and (\(identifierClause))"

    // `NSXPCConnection.setCodeSigningRequirement(_:)` raises an *Objective-C exception* (not a
    // Swift error) for a malformed requirement string, which Swift cannot catch — so validate the
    // syntax ourselves first with `SecRequirementCreateWithString`, which reports failure as an
    // OSStatus instead. This should only ever fail if the template above has a bug (it never
    // depends on unsanitized input — `identifiers` is always one of our own constants).
    var requirementRef: SecRequirement?
    let status = SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirementRef)
    guard status == errSecSuccess else {
      return unauthenticatedFallback(
        reason:
          "generated requirement failed to parse (SecRequirementCreateWithString status \(status)); this is a bug",
        isDebugBuild: isDebugBuild
      )
    }
    return .enforce(text)
  }

  /// Chooses between `.developmentFallback` and `.rejectAll` for a situation where no real
  /// `Requirement` could be built (no team identifier, or a bug in the template above): DEBUG
  /// builds get the permissive local-dev behavior; anything else fails closed and logs why, since
  /// this is the only path an unauthenticated peer could otherwise talk to the vault helper.
  private static func unauthenticatedFallback(reason: String, isDebugBuild: Bool) -> Requirement {
    guard !isDebugBuild else {
      return .developmentFallback(reason: reason)
    }
    FileHandle.standardError.write(
      Data("LilPasswordsAgent: refusing every connection — \(reason)\n".utf8)
    )
    return .rejectAll(reason: reason)
  }

  /// The team identifier from the *running process's own* code signature, or `nil` if it has
  /// none (unsigned, or ad-hoc signed — ad-hoc signing has no certificate, hence no team).
  static func currentProcessTeamIdentifier() -> String? {
    var codeRef: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &codeRef) == errSecSuccess, let code = codeRef else { return nil }

    var infoRef: CFDictionary?
    // `SecCodeCopySigningInformation` takes a `SecStaticCode`; `SecCode` (a running instance) is
    // toll-free bridgeable to it, hence the forced cast rather than a public conversion API.
    guard
      SecCodeCopySigningInformation(code as! SecStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        == errSecSuccess,
      let info = infoRef as? [String: Any]
    else { return nil }

    return info[kSecCodeInfoTeamIdentifier as String] as? String
  }
}
