import LilPasswordsKit

/// How the user wants a conflicting row (one that matches an existing vault item on account, but
/// differs in some field) resolved. Only meaningful for a row whose ``ImportPreviewRow/decision``
/// is `.conflict`; new and duplicate rows have a single, fixed outcome (add, skip) with nothing to
/// choose.
enum ImportConflictResolution: CaseIterable {
  /// Leave the existing vault item untouched; don't import this row at all.
  case keepExisting
  /// Overwrite the existing vault item's fields with the imported row's values.
  case replace
  /// Import this row as a brand-new, separate item, leaving the existing one as-is.
  case keepBoth

  var title: String {
    switch self {
    case .keepExisting: return "Keep Existing"
    case .replace: return "Replace"
    case .keepBoth: return "Keep Both"
    }
  }
}

/// One row of the import preview table: an ``ImportMergePlanner`` decision for a single imported
/// credential, plus — for a conflict — which resolution the user currently has selected. Defaults
/// every conflict to "Keep Existing", the safest choice (nothing in the vault is overwritten
/// unless the user explicitly picks "Replace" or adds a second copy with "Keep Both").
struct ImportPreviewRow {
  let decision: ImportPlanDecision
  var resolution: ImportConflictResolution = .keepExisting

  var imported: ImportedCredential {
    switch decision {
    case .new(let imported): return imported
    case .duplicate(let imported, _): return imported
    case .conflict(let imported, _): return imported
    }
  }

  var existing: ExistingCredential? {
    switch decision {
    case .new: return nil
    case .duplicate(_, let existing): return existing
    case .conflict(_, let existing): return existing
    }
  }

  var statusText: String {
    switch decision {
    case .new: return "New"
    case .duplicate: return "Duplicate"
    case .conflict: return "Conflict"
    }
  }

  var isConflict: Bool {
    if case .conflict = decision { return true }
    return false
  }
}

extension Array where Element == ImportPreviewRow {
  static func rows(for plan: ImportPlan) -> [ImportPreviewRow] {
    plan.decisions.map { ImportPreviewRow(decision: $0) }
  }

  var newCount: Int { filter { if case .new = $0.decision { return true } else { return false } }.count }
  var duplicateCount: Int { filter { if case .duplicate = $0.decision { return true } else { return false } }.count }
  var conflictCount: Int { filter(\.isConflict).count }
}
