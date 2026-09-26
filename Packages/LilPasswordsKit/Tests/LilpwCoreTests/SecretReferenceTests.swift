import LilpwCore
import Testing

@Suite struct SecretReferenceTests {
  @Test func parsesAWellFormedReference() throws {
    let reference = try #require(SecretReference(string: "lilpw://github/password"))
    #expect(reference.item == "github")
    #expect(reference.field == .password)
  }

  @Test func fieldNameIsCaseInsensitive() throws {
    let reference = try #require(SecretReference(string: "lilpw://github/PASSWORD"))
    #expect(reference.field == .password)
  }

  @Test func percentDecodesTheItemHost() throws {
    let reference = try #require(SecretReference(string: "lilpw://My%20Bank/username"))
    #expect(reference.item == "My Bank")
    #expect(reference.field == .username)
  }

  @Test func rejectsAWrongScheme() {
    #expect(SecretReference(string: "op://github/password") == nil)
  }

  @Test func rejectsAMissingItem() {
    #expect(SecretReference(string: "lilpw:///password") == nil)
  }

  @Test func rejectsAnUnrecognizedField() {
    #expect(SecretReference(string: "lilpw://github/secretquestion") == nil)
  }

  @Test func rejectsAMissingField() {
    #expect(SecretReference(string: "lilpw://github") == nil)
  }

  @Test func rejectsExtraPathSegments() {
    #expect(SecretReference(string: "lilpw://github/password/extra") == nil)
  }
}
