import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct SecurityFindingsTests {
  @Test func groupsReusedPasswordsTogether() {
    let a = PasswordItem(title: "A", password: "Sunlit-Paper-63-XyZ!")
    let b = PasswordItem(title: "B", password: "Sunlit-Paper-63-XyZ!")
    let c = PasswordItem(title: "C", password: "Different-Unique-91-QrS!")

    let findings = SecurityFindings.build(from: [a, b, c])

    let reused = findings.groups.first { $0.kind == .reused }
    #expect(Set(reused?.itemIDs ?? []) == Set([a.id, b.id]))
  }

  @Test func flagsWeakPasswords() {
    let weak = PasswordItem(title: "Weak", password: "password")
    let strong = PasswordItem(title: "Strong", password: "Correct-Horse-Battery-Staple-42!")

    let findings = SecurityFindings.build(from: [weak, strong])

    let weakGroup = findings.groups.first { $0.kind == .weak }
    #expect(weakGroup?.itemIDs == [weak.id])
  }

  @Test func excludesDeletedItemsEntirely() {
    var deleted = PasswordItem(title: "Deleted", password: "password")
    deleted.deletedAt = Date()

    let findings = SecurityFindings.build(from: [deleted])
    #expect(findings.groups.isEmpty)
  }

  @Test func hiddenWarningDropsTheItemButStillFlagsItsReusePartner() {
    var hidden = PasswordItem(title: "Hidden", password: "Shared-Secret-77-Abc!")
    hidden.securityWarningHidden = true
    let visible = PasswordItem(title: "Visible", password: "Shared-Secret-77-Abc!")

    let findings = SecurityFindings.build(from: [hidden, visible])

    let reused = findings.groups.first { $0.kind == .reused }
    #expect(reused?.itemIDs == [visible.id])
    #expect(findings.uniqueItemIDs.contains(hidden.id) == false)
  }

  @Test func uniqueItemIDsDeduplicatesAnItemFlaggedByBothChecks() {
    let a = PasswordItem(title: "A", password: "password")
    let b = PasswordItem(title: "B", password: "password")

    let findings = SecurityFindings.build(from: [a, b])
    // "password" is both a common (weak) password and reused between a and b.
    #expect(findings.uniqueItemIDs == Set([a.id, b.id]))
  }

  @Test func emptyGroupsAreOmittedNotReturnedEmpty() {
    let clean = PasswordItem(title: "Clean", password: "Correct-Horse-Battery-Staple-42!")
    let findings = SecurityFindings.build(from: [clean])
    #expect(findings.groups.isEmpty)
    #expect(findings.uniqueItemIDs.isEmpty)
  }

  @Test func flagsCompromisedIDsPassedIn() {
    let leaked = PasswordItem(title: "Leaked", password: "password123")
    let safe = PasswordItem(title: "Safe", password: "Correct-Horse-Battery-Staple-42!")

    let findings = SecurityFindings.build(from: [leaked, safe], compromisedIDs: [leaked.id])

    let compromised = findings.groups.first { $0.kind == .compromised }
    #expect(compromised?.itemIDs == [leaked.id])
  }

  @Test func compromisedGroupComesBeforeReusedAndWeak() {
    let compromised = PasswordItem(title: "Compromised", password: "Unique-One-77-Xyz!")
    let reusedA = PasswordItem(title: "ReusedA", password: "Shared-Two-88-Xyz!")
    let reusedB = PasswordItem(title: "ReusedB", password: "Shared-Two-88-Xyz!")
    let weak = PasswordItem(title: "Weak", password: "password")

    let findings = SecurityFindings.build(
      from: [compromised, reusedA, reusedB, weak],
      compromisedIDs: [compromised.id]
    )

    #expect(findings.groups.map(\.kind) == [.compromised, .reused, .weak])
  }

  @Test func ignoresCompromisedIDsForDeletedOrHiddenWarningItems() {
    var deleted = PasswordItem(title: "Deleted", password: "password123")
    deleted.deletedAt = Date()
    var hidden = PasswordItem(title: "Hidden", password: "password123")
    hidden.securityWarningHidden = true

    let findings = SecurityFindings.build(
      from: [deleted, hidden],
      compromisedIDs: [deleted.id, hidden.id]
    )

    #expect(findings.groups.isEmpty)
  }

  @Test func compromisedContributesToUniqueItemIDsAlongsideOtherKinds() {
    let compromisedOnly = PasswordItem(title: "A", password: "Unique-One-77-Xyz!")
    let weakOnly = PasswordItem(title: "B", password: "password")

    let findings = SecurityFindings.build(
      from: [compromisedOnly, weakOnly],
      compromisedIDs: [compromisedOnly.id]
    )

    #expect(findings.uniqueItemIDs == Set([compromisedOnly.id, weakOnly.id]))
  }
}
