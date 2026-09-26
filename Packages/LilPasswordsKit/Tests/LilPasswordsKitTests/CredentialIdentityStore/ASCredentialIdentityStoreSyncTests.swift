import AuthenticationServices
import Foundation
import Testing

@testable import LilPasswordsKit

/// 851-2441: the ticket's "identity mapping" tests. Exercises ``ASCredentialIdentityStoreSync
/// .identities(for:)`` directly — a pure, `Sendable`-safe static function — rather than
/// ``ASCredentialIdentityStoreSync/sync(items:)`` itself, since the latter depends on the real,
/// environment-dependent `ASCredentialIdentityStore.shared` (whether *this* build's AutoFill
/// extension is actually registered and enabled in System Settings — see that type's own
/// documentation on the provisioning-profile blocker). None of that affects the mapping logic
/// under test here.
@Suite struct ASCredentialIdentityStoreSyncTests {
  @Test func itemWithAUsernameAndAWebsiteProducesAnIdentity() {
    let item = PasswordItem(
      title: "Netflix",
      usernames: ["octocat"],
      password: "hunter2",
      websites: [URL(string: "https://www.netflix.com")!]
    )

    let identities = ASCredentialIdentityStoreSync.identities(for: [item])

    #expect(identities.count == 1)
    #expect(identities[0].user == "octocat")
    #expect(identities[0].recordIdentifier == item.id.uuidString)
    #expect(identities[0].serviceIdentifier.identifier == "www.netflix.com")
    #expect(identities[0].serviceIdentifier.type == .domain)
  }

  @Test func itemWithNoUsernameIsExcluded() {
    let item = PasswordItem(
      title: "Netflix",
      usernames: [],
      password: "hunter2",
      websites: [URL(string: "https://www.netflix.com")!]
    )

    #expect(ASCredentialIdentityStoreSync.identities(for: [item]).isEmpty)
  }

  /// An item can carry a `usernames` array containing only empty strings (e.g. a placeholder the
  /// user never filled in) — that's not a *missing* username field, but it's just as useless for
  /// AutoFill as no username at all, so it's excluded the same way.
  @Test func itemWithOnlyBlankUsernamesIsExcluded() {
    let item = PasswordItem(
      title: "Netflix",
      usernames: [""],
      password: "hunter2",
      websites: [URL(string: "https://www.netflix.com")!]
    )

    #expect(ASCredentialIdentityStoreSync.identities(for: [item]).isEmpty)
  }

  @Test func itemWithNoWebsiteIsExcluded() {
    let item = PasswordItem(title: "Netflix", usernames: ["octocat"], password: "hunter2", websites: [])

    #expect(ASCredentialIdentityStoreSync.identities(for: [item]).isEmpty)
  }

  /// A website URL with no resolvable host (e.g. a bare local path) is treated the same as no
  /// website at all — there'd be nothing meaningful to key the identity's service identifier by.
  @Test func itemWithAWebsiteThatHasNoHostIsExcluded() {
    let item = PasswordItem(
      title: "Weird",
      usernames: ["octocat"],
      password: "hunter2",
      websites: [URL(string: "file:///notes.txt")!]
    )

    #expect(ASCredentialIdentityStoreSync.identities(for: [item]).isEmpty)
  }

  @Test func softDeletedItemIsExcludedEvenWithAUsernameAndWebsite() {
    let item = PasswordItem(
      title: "Netflix",
      usernames: ["octocat"],
      password: "hunter2",
      websites: [URL(string: "https://www.netflix.com")!],
      deletedAt: Date()
    )

    #expect(ASCredentialIdentityStoreSync.identities(for: [item]).isEmpty)
  }

  @Test func onlyTheFirstNonBlankUsernameAndFirstWebsiteAreUsed() {
    let item = PasswordItem(
      title: "Netflix",
      usernames: ["", "octocat", "octocat2"],
      password: "hunter2",
      websites: [URL(string: "https://www.netflix.com")!, URL(string: "https://help.netflix.com")!]
    )

    let identities = ASCredentialIdentityStoreSync.identities(for: [item])

    #expect(identities.count == 1)
    #expect(identities[0].user == "octocat")
    #expect(identities[0].serviceIdentifier.identifier == "www.netflix.com")
  }

  @Test func aMixOfEligibleAndIneligibleItemsOnlyMapsTheEligibleOnes() {
    let eligible = PasswordItem(
      title: "Netflix",
      usernames: ["octocat"],
      password: "hunter2",
      websites: [URL(string: "https://www.netflix.com")!]
    )
    let noUsername = PasswordItem(
      title: "No username",
      websites: [URL(string: "https://example.com")!]
    )
    let noWebsite = PasswordItem(title: "No website", usernames: ["octocat"])
    let deleted = PasswordItem(
      title: "Deleted",
      usernames: ["octocat"],
      websites: [URL(string: "https://example.com")!],
      deletedAt: Date()
    )

    let identities = ASCredentialIdentityStoreSync.identities(for: [eligible, noUsername, noWebsite, deleted])

    #expect(identities.count == 1)
    #expect(identities[0].recordIdentifier == eligible.id.uuidString)
  }

  @Test func emptyItemListProducesNoIdentities() {
    #expect(ASCredentialIdentityStoreSync.identities(for: []).isEmpty)
  }

  // MARK: - 851-2442: passkeyIdentities(for:)

  @available(macOS 14, *)
  @Test func aPasskeyIdentityProducesAnASPasskeyCredentialIdentityCarryingNoSecret() {
    let id = UUID()
    let passkey = PasskeyIdentity(
      id: id,
      relyingPartyIdentifier: "webauthn.io",
      userName: "octocat",
      userHandle: Data([1, 2, 3, 4]),
      credentialId: Data([5, 6, 7, 8])
    )

    let identities = ASCredentialIdentityStoreSync.passkeyIdentities(for: [passkey])

    #expect(identities.count == 1)
    #expect(identities[0].relyingPartyIdentifier == "webauthn.io")
    #expect(identities[0].userName == "octocat")
    #expect(identities[0].userHandle == Data([1, 2, 3, 4]))
    #expect(identities[0].credentialID == Data([5, 6, 7, 8]))
    #expect(identities[0].recordIdentifier == id.uuidString)
  }

  @available(macOS 14, *)
  @Test func aPasskeyIdentityWithNoRelyingPartyIdentifierIsExcluded() {
    let passkey = PasskeyIdentity(
      id: UUID(),
      relyingPartyIdentifier: "",
      userName: "octocat",
      userHandle: Data([1, 2, 3, 4]),
      credentialId: Data([5, 6, 7, 8])
    )

    #expect(ASCredentialIdentityStoreSync.passkeyIdentities(for: [passkey]).isEmpty)
  }

  @available(macOS 14, *)
  @Test func emptyPasskeyIdentityListProducesNoIdentities() {
    #expect(ASCredentialIdentityStoreSync.passkeyIdentities(for: []).isEmpty)
  }
}
