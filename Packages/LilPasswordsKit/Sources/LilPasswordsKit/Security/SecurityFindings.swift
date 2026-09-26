import Foundation

/// Which kind of local security issue a ``SecurityFindings/Group`` collects. Matches the
/// sections Apple Passwords' own Security view groups flagged items under.
///
/// `compromised` (851-2458) is the one kind ``SecurityFindings/build(from:auditor:compromisedIDs:)``
/// can't determine on its own: unlike ``SecurityAuditor``'s reused/weak checks, which are pure and
/// need nothing but the passwords already in memory, "has this password appeared in a known data
/// leak" requires an opt-in, k-anonymity lookup against Have I Been Pwned's Pwned Passwords range
/// API (``CompromisedPasswordChecker``) — network I/O that only runs in the app, only while the
/// user has turned it on, and never inside this pure, synchronous builder. Callers that have
/// already run that check pass its result in as `compromisedIDs`.
public enum SecurityIssueKind: String, Sendable, Hashable, CaseIterable {
  case compromised
  case reused
  case weak

  /// The section header shown above this group's rows.
  public var groupTitle: String {
    switch self {
    case .compromised: return "Compromised Passwords"
    case .reused: return "Reused Passwords"
    case .weak: return "Weak Passwords"
    }
  }

  /// The reason text shown on each row in this group, matching the wording Apple Passwords uses
  /// for the same recommendation.
  public var reasonText: String {
    switch self {
    case .compromised:
      return
        "This password has appeared in a data leak, which puts this account at high risk of "
        + "compromise. You should change your password immediately."
    case .reused:
      return
        "This password has been used on multiple accounts. Reusing passwords makes it easier "
        + "for someone who obtains one of your passwords to access your other accounts. You "
        + "should change your password on each of these accounts to something unique."
    case .weak:
      return
        "This password is easy to guess. You should change it to a more secure password."
    }
  }
}

/// The Security view's data, grouped and ready to render: which items are flagged, why, and in
/// what order the groups (and the items within them) should appear.
///
/// Building this is intentionally separated from any AppKit view — it's pure, deterministic, and
/// depends only on ``SecurityAuditor`` and the items handed in, so the Security view (851-2419)
/// can be exercised by tests without any `NSTableView` in the loop.
public struct SecurityFindings: Sendable, Hashable {
  /// One section of the Security view: every flagged item for a single ``SecurityIssueKind``, in
  /// stable order (the order ``build(from:auditor:)`` first encountered them in `items`).
  public struct Group: Sendable, Hashable {
    public let kind: SecurityIssueKind
    public let itemIDs: [UUID]
  }

  /// Non-empty groups, in a fixed order — compromised before reused before weak, matching Apple
  /// Passwords' own Security view ordering (compromised is the most urgent finding, so it leads).
  public let groups: [Group]

  /// Every flagged item's id, deduplicated — an item that's both reused and weak is still one
  /// item needing attention. This is what the sidebar badge (``SidebarCategory/security``)
  /// counts.
  public var uniqueItemIDs: Set<UUID> {
    groups.reduce(into: Set<UUID>()) { $0.formUnion($1.itemIDs) }
  }

  /// Runs `auditor` over every non-deleted item in `items` and groups the results.
  ///
  /// Deleted items (``PasswordItem/deletedAt`` set) never contribute a finding, and never
  /// participate in reuse grouping either — a password shared only with something already in
  /// Recently Deleted isn't "reused" from the user's point of view. An item whose
  /// ``PasswordItem/securityWarningHidden`` is `true` is excluded from every group here, the same
  /// way ``SecurityAuditor/audit(_:)`` excludes it from its own output, but (per that method's
  /// documentation) still counts toward flagging *other* items it shares a password with.
  ///
  /// - Parameter compromisedIDs: Ids of items whose password ``CompromisedPasswordChecker`` has
  ///   already confirmed appears in a known data leak (851-2458). Empty unless a caller has
  ///   opted in (Settings → General → "Detect compromised passwords") and already run that async
  ///   check itself — this method stays synchronous and never performs the lookup. Ids outside
  ///   `items`, already-deleted, or hidden-warning items are ignored, same as the other two kinds.
  public static func build(
    from items: [PasswordItem],
    auditor: SecurityAuditor = SecurityAuditor(),
    compromisedIDs: Set<UUID> = []
  ) -> SecurityFindings {
    let candidates = items.nonDeleted()
    let inputs = candidates.map {
      AuditInput(id: $0.id, password: $0.password, hiddenWarning: $0.securityWarningHidden)
    }
    let issuesByID = auditor.audit(inputs)

    var compromisedGroupIDs: [UUID] = []
    var reusedIDs: [UUID] = []
    var weakIDs: [UUID] = []
    for item in candidates {
      guard !item.securityWarningHidden else { continue }
      if compromisedIDs.contains(item.id) {
        compromisedGroupIDs.append(item.id)
      }
      guard let issues = issuesByID[item.id] else { continue }
      if issues.contains(.reused) {
        reusedIDs.append(item.id)
      }
      if issues.contains(where: { if case .weak = $0 { return true } else { return false } }) {
        weakIDs.append(item.id)
      }
    }

    var groups: [Group] = []
    if !compromisedGroupIDs.isEmpty {
      groups.append(Group(kind: .compromised, itemIDs: compromisedGroupIDs))
    }
    if !reusedIDs.isEmpty {
      groups.append(Group(kind: .reused, itemIDs: reusedIDs))
    }
    if !weakIDs.isEmpty {
      groups.append(Group(kind: .weak, itemIDs: weakIDs))
    }
    return SecurityFindings(groups: groups)
  }
}
