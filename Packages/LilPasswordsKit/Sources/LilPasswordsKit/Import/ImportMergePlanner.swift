import Foundation

/// A per-credential outcome of comparing an import against the existing vault contents.
public enum ImportPlanDecision: Equatable, Sendable {
  /// No existing item matches; this should be added as a new item.
  case new(ImportedCredential)

  /// An existing item matches on account (username + site) and every field is identical;
  /// importing it again would add nothing, so the default action is to skip it.
  case duplicate(imported: ImportedCredential, existing: ExistingCredential)

  /// An existing item matches on account (username + site) but some field differs (password,
  /// notes, OTP secret, ...). The user needs to choose whether to keep the existing item, replace
  /// it with the imported one, or merge the two.
  case conflict(imported: ImportedCredential, existing: ExistingCredential)
}

/// A finished dedupe/merge plan for one import.
public struct ImportPlan: Equatable, Sendable {
  public var decisions: [ImportPlanDecision]

  public init(decisions: [ImportPlanDecision]) {
    self.decisions = decisions
  }

  public var newCredentials: [ImportedCredential] {
    decisions.compactMap {
      if case .new(let credential) = $0 { return credential }
      return nil
    }
  }

  public var duplicates: [(imported: ImportedCredential, existing: ExistingCredential)] {
    decisions.compactMap {
      if case .duplicate(let imported, let existing) = $0 { return (imported, existing) }
      return nil
    }
  }

  public var conflicts: [(imported: ImportedCredential, existing: ExistingCredential)] {
    decisions.compactMap {
      if case .conflict(let imported, let existing) = $0 { return (imported, existing) }
      return nil
    }
  }
}

/// Plans how a batch of ``ImportedCredential`` values should be merged into the existing vault.
///
/// Two credentials are considered to describe the same account when their usernames match
/// (case-insensitively) and they share at least one URL host — or, if neither side has a URL, when
/// their titles match. A matched pair with every field equal is a ``ImportPlanDecision/duplicate``;
/// a matched pair that differs anywhere is a ``ImportPlanDecision/conflict``, since some field (most
/// often the password) needs a user decision about which value wins.
public enum ImportMergePlanner {
  public static func plan(
    importing credentials: [ImportedCredential],
    against existing: [ExistingCredential]
  ) -> ImportPlan {
    let decisions = credentials.map { imported -> ImportPlanDecision in
      guard let match = bestMatch(for: imported, in: existing) else {
        return .new(imported)
      }
      return isIdentical(imported, match)
        ? .duplicate(imported: imported, existing: match) : .conflict(imported: imported, existing: match)
    }
    return ImportPlan(decisions: decisions)
  }

  private static func bestMatch(for imported: ImportedCredential, in existing: [ExistingCredential])
    -> ExistingCredential?
  {
    let importedUsername = normalized(imported.username)
    let importedHosts = hosts(for: imported.urls)
    let importedTitle = normalized(imported.title)

    return existing.first { candidate in
      guard normalized(candidate.username) == importedUsername else { return false }

      let candidateHosts = hosts(for: candidate.urls)
      if !importedHosts.isEmpty || !candidateHosts.isEmpty {
        return !importedHosts.isDisjoint(with: candidateHosts)
      }
      // Neither side has a usable URL: fall back to comparing titles.
      return normalized(candidate.title) == importedTitle
    }
  }

  private static func isIdentical(_ imported: ImportedCredential, _ existing: ExistingCredential) -> Bool {
    // URLs are compared by normalized host rather than raw string, so a trailing path or a
    // "www." prefix doesn't turn an otherwise-identical entry into a conflict.
    normalized(imported.title) == normalized(existing.title) && imported.password == existing.password
      && hosts(for: imported.urls) == hosts(for: existing.urls) && (imported.notes ?? "") == (existing.notes ?? "")
      && (imported.otpAuth ?? "") == (existing.otpAuth ?? "")
  }

  private static func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func hosts(for urls: [String]) -> Set<String> {
    Set(urls.compactMap(normalizedHost))
  }

  private static func normalizedHost(from urlString: String) -> String? {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let host = URLComponents(string: withScheme)?.host, !host.isEmpty else { return nil }

    let lowercased = host.lowercased()
    return lowercased.hasPrefix("www.") ? String(lowercased.dropFirst(4)) : lowercased
  }
}
