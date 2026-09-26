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
}
