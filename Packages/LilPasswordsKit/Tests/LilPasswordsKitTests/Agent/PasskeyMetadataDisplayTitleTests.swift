import Foundation
import Testing

@testable import LilPasswordsKit

/// Covers `PasskeyMetadata.displayTitle` (851-2442's UI polish pass): the string that drives the
/// Passkeys list row's title, the detail card's title *and* "Website" field, and — since
/// `MonogramIcon.letter(for:)`/`tint(for:)` both take this same string — the row/detail
/// monogram's letter and `MonogramPalette` color too.
@Suite struct PasskeyMetadataDisplayTitleTests {
  private func makeMetadata(relyingPartyIdentifier: String = "amazon.com", website: URL?) -> PasskeyMetadata {
    PasskeyMetadata(
      id: UUID(),
      relyingPartyIdentifier: relyingPartyIdentifier,
      userName: "alice",
      userDisplayName: "Alice",
      website: website,
      createdAt: Date(),
      lastUsedAt: nil
    )
  }

  @Test func stripsALeadingWWWFromTheWebsiteHost() {
    let metadata = makeMetadata(website: URL(string: "https://www.amazon.com"))
    #expect(metadata.displayTitle == "amazon.com")
  }

  @Test func leavesAHostWithoutAWWWPrefixUntouched() {
    let metadata = makeMetadata(relyingPartyIdentifier: "webauthn.io", website: URL(string: "https://webauthn.io"))
    #expect(metadata.displayTitle == "webauthn.io")
  }

  @Test func fallsBackToTheRawRelyingPartyIdentifierWhenThereIsNoWebsiteURL() {
    let metadata = makeMetadata(relyingPartyIdentifier: "www.example.com", website: nil)
    #expect(metadata.displayTitle == "example.com")
  }

  @Test @MainActor func theMonogramLetterAndColorAgreeWithTheWWWStrippedTitle() {
    // Before this fix, `displayTitle` (then a raw `website?.host`) was "www.amazon.com", whose
    // monogram would misleadingly read "W" rather than the "A" a person expects for Amazon.
    let metadata = makeMetadata(website: URL(string: "https://www.amazon.com"))
    #expect(MonogramIcon.letter(for: metadata.displayTitle) == "A")
    #expect(MonogramIcon.tint(for: metadata.displayTitle) == MonogramIcon.tint(for: "amazon.com"))
  }
}
