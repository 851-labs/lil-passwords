import LilpassCore
import Testing

@Suite struct SecretReferenceTests {
  @Test func parsesAWellFormedReference() throws {
    let reference = try #require(SecretReference(string: "lilpass://github/password"))
    #expect(reference.item == "github")
    #expect(reference.field == .password)
  }

  @Test func fieldNameIsCaseInsensitive() throws {
    let reference = try #require(SecretReference(string: "lilpass://github/PASSWORD"))
    #expect(reference.field == .password)
  }

  @Test func percentDecodesTheItemHost() throws {
    let reference = try #require(SecretReference(string: "lilpass://My%20Bank/username"))
    #expect(reference.item == "My Bank")
    #expect(reference.field == .username)
  }

  @Test func rejectsAWrongScheme() {
    #expect(SecretReference(string: "op://github/password") == nil)
  }

  @Test func rejectsAMissingItem() {
    #expect(SecretReference(string: "lilpass:///password") == nil)
  }

  @Test func rejectsAnUnrecognizedField() {
    #expect(SecretReference(string: "lilpass://github/secretquestion") == nil)
  }

  @Test func rejectsAMissingField() {
    #expect(SecretReference(string: "lilpass://github") == nil)
  }

  @Test func rejectsExtraPathSegments() {
    #expect(SecretReference(string: "lilpass://github/password/extra") == nil)
  }
}
