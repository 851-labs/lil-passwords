import Testing

@testable import LilPasswordsKit

@Suite struct ImportMergePlannerTests {
  @Test func noExistingCredentialsMeansEverythingIsNew() {
    let imported = [
      ImportedCredential(title: "Acme", username: "alice", password: "hunter2", urls: ["https://acme.example.com"])
    ]
    let plan = ImportMergePlanner.plan(importing: imported, against: [])
    #expect(plan.newCredentials == imported)
    #expect(plan.duplicates.isEmpty)
    #expect(plan.conflicts.isEmpty)
  }

  @Test func matchingUsernameAndHostWithIdenticalFieldsIsADuplicate() {
    let imported = ImportedCredential(
      title: "Acme",
      username: "Alice@Example.com",
      password: "hunter2",
      urls: ["https://www.acme.example.com/login"],
      notes: "work account"
    )
    let existing = ExistingCredential(
      id: "1",
      title: "acme",
      username: "alice@example.com",
      password: "hunter2",
      urls: ["https://acme.example.com"],
      notes: "work account"
    )
    let plan = ImportMergePlanner.plan(importing: [imported], against: [existing])
    #expect(plan.decisions == [.duplicate(imported: imported, existing: existing)])
  }

  @Test func matchingAccountWithDifferentPasswordIsAConflict() {
    let imported = ImportedCredential(
      title: "Acme", username: "alice", password: "new-password", urls: ["https://acme.example.com"])
    let existing = ExistingCredential(
      id: "1", title: "Acme", username: "alice", password: "old-password", urls: ["https://acme.example.com"])
    let plan = ImportMergePlanner.plan(importing: [imported], against: [existing])
    #expect(plan.decisions == [.conflict(imported: imported, existing: existing)])
  }

  @Test func matchingAccountWithDifferentNotesIsAConflict() {
    let imported = ImportedCredential(
      title: "Acme", username: "alice", password: "hunter2", urls: ["https://acme.example.com"], notes: "new note")
    let existing = ExistingCredential(
      id: "1", title: "Acme", username: "alice", password: "hunter2", urls: ["https://acme.example.com"], notes: nil)
    let plan = ImportMergePlanner.plan(importing: [imported], against: [existing])
    #expect(plan.decisions == [.conflict(imported: imported, existing: existing)])
  }

  @Test func sameUsernameDifferentSiteIsNotAMatch() {
    let imported = ImportedCredential(
      title: "Other Corp", username: "alice", password: "hunter2", urls: ["https://other.example.com"])
    let existing = ExistingCredential(
      id: "1", title: "Acme", username: "alice", password: "hunter2", urls: ["https://acme.example.com"])
    let plan = ImportMergePlanner.plan(importing: [imported], against: [existing])
    #expect(plan.decisions == [.new(imported)])
  }

  @Test func differentUsernameSameSiteIsNotAMatch() {
    let imported = ImportedCredential(
      title: "Acme", username: "bob", password: "hunter2", urls: ["https://acme.example.com"])
    let existing = ExistingCredential(
      id: "1", title: "Acme", username: "alice", password: "hunter2", urls: ["https://acme.example.com"])
    let plan = ImportMergePlanner.plan(importing: [imported], against: [existing])
    #expect(plan.decisions == [.new(imported)])
  }

  @Test func noURLOnEitherSideFallsBackToTitleMatch() {
    let imported = ImportedCredential(title: "Home Wifi", username: "alice", password: "hunter2")
    let existing = ExistingCredential(id: "1", title: "home wifi", username: "alice", password: "old-pass")
    let plan = ImportMergePlanner.plan(importing: [imported], against: [existing])
    #expect(plan.decisions == [.conflict(imported: imported, existing: existing)])
  }

  @Test func mixedBatchProducesAllThreeDecisionKinds() {
    let brandNew = ImportedCredential(
      title: "New Co", username: "carol", password: "p1", urls: ["https://new.example.com"])
    let dup = ImportedCredential(
      title: "Acme", username: "alice", password: "hunter2", urls: ["https://acme.example.com"])
    let conflicting = ImportedCredential(
      title: "Beta", username: "bob", password: "new-pass", urls: ["https://beta.example.com"])

    let existing = [
      ExistingCredential(
        id: "1", title: "Acme", username: "alice", password: "hunter2", urls: ["https://acme.example.com"]),
      ExistingCredential(
        id: "2", title: "Beta", username: "bob", password: "old-pass", urls: ["https://beta.example.com"]),
    ]

    let plan = ImportMergePlanner.plan(importing: [brandNew, dup, conflicting], against: existing)
    #expect(plan.newCredentials == [brandNew])
    #expect(plan.duplicates.map(\.imported) == [dup])
    #expect(plan.conflicts.map(\.imported) == [conflicting])
  }

  @Test func multipleURLsMatchIfAnyHostOverlapsButExtraHostsMakeItAConflict() {
    // The imported item carries an extra host (blog.example.com) the existing item doesn't have,
    // so the two aren't byte-for-byte identical even though they clearly describe the same
    // account — that's a conflict for the user to resolve, not a silent duplicate.
    let imported = ImportedCredential(
      title: "Acme", username: "alice", password: "hunter2",
      urls: ["https://blog.example.com", "https://acme.example.com/account"])
    let existing = ExistingCredential(
      id: "1", title: "Acme", username: "alice", password: "hunter2", urls: ["https://acme.example.com"])
    let plan = ImportMergePlanner.plan(importing: [imported], against: [existing])
    #expect(plan.decisions == [.conflict(imported: imported, existing: existing)])
  }

  @Test func matchingHostsWithDifferentPathsAreStillADuplicate() {
    let imported = ImportedCredential(
      title: "Acme", username: "alice", password: "hunter2", urls: ["https://acme.example.com/account/login"])
    let existing = ExistingCredential(
      id: "1", title: "Acme", username: "alice", password: "hunter2", urls: ["https://acme.example.com"])
    let plan = ImportMergePlanner.plan(importing: [imported], against: [existing])
    #expect(plan.decisions == [.duplicate(imported: imported, existing: existing)])
  }
}
