import Foundation
import Security

/// Builds the code-signing requirement that validates the far side of an `NSXPCConnection`: the
/// helper checks that a connecting client is really the app or `lilpw`, and `AgentClient` checks
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

    /// No team identifier could be determined for the running process — an unsigned or
    /// ad-hoc-signed build (the default per `Config/Base.xcconfig`, and always true in CI, which
    /// builds unsigned). Connections are accepted without code-signature validation.
    ///
    /// This is the documented local-dev fallback: an ad-hoc/unsigned build has no team identifier
    /// to build a requirement from, so enforcing one would make the agent reject every client on
    /// a machine without a configured `Config/Local.xcconfig` signing identity, including CI.
    /// Anyone who *does* configure a personal team there (see that file) gets real enforcement
    /// with no code change.
    case developmentFallback(reason: String)
  }

  /// Builds a `Requirement` accepting only peers whose code signature has our own running
  /// process's team identifier and one of `identifiers`' bundle identifiers.
  public static func requirement(acceptingPeers identifiers: [PeerIdentifier]) -> Requirement {
    requirement(acceptingPeers: identifiers, teamIdentifier: currentProcessTeamIdentifier())
  }

  /// The `teamIdentifier`-parameterized half of ``requirement(acceptingPeers:)``, split out so
  /// tests can exercise the string-building and syntax-validation logic without depending on how
  /// the test binary itself happens to be signed.
  static func requirement(acceptingPeers identifiers: [PeerIdentifier], teamIdentifier: String?) -> Requirement {
    guard let teamIdentifier else {
      return .developmentFallback(
        reason: "no team identifier on the running process's own code signature (unsigned or ad-hoc build)"
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
      return .developmentFallback(
        reason: "generated requirement failed to parse (SecRequirementCreateWithString status \(status)); this is a bug"
      )
    }
    return .enforce(text)
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
