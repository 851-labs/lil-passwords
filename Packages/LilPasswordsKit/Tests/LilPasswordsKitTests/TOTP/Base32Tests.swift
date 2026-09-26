import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct Base32Tests {
  struct Fixture: Sendable {
    let input: String
    let encoded: String
  }

  // RFC 4648 §10 test vectors.
  static let fixtures: [Fixture] = [
    Fixture(input: "", encoded: ""),
    Fixture(input: "f", encoded: "MY======"),
    Fixture(input: "fo", encoded: "MZXQ===="),
    Fixture(input: "foo", encoded: "MZXW6==="),
    Fixture(input: "foob", encoded: "MZXW6YQ="),
    Fixture(input: "fooba", encoded: "MZXW6YTB"),
    Fixture(input: "foobar", encoded: "MZXW6YTBOI======"),
  ]

  @Test(arguments: fixtures)
  func rfc4648Vectors(_ fixture: Fixture) {
    let data = Data(fixture.input.utf8)
    #expect(Base32.encode(data, padded: true) == fixture.encoded)
    #expect(Base32.decode(fixture.encoded) == data)
  }

  @Test func unpaddedEncodeOmitsTrailingEquals() {
    #expect(Base32.encode(Data("foobar".utf8)) == "MZXW6YTBOI")
    #expect(Base32.encode(Data("foo".utf8)) == "MZXW6")
  }

  @Test func decodeIsCaseInsensitive() {
    #expect(Base32.decode("mzxw6ytboi") == Data("foobar".utf8))
    #expect(Base32.decode("MZXW6YTBOI") == Data("foobar".utf8))
  }

  @Test func decodeToleratesGroupSpacingAndDashes() {
    #expect(Base32.decode("MZXW 6YTB OI") == Data("foobar".utf8))
    #expect(Base32.decode("MZXW-6YTB-OI") == Data("foobar".utf8))
  }

  @Test func decodeRejectsInvalidCharacters() {
    #expect(Base32.decode("MZXW1YTB") == nil)  // '1' is not in the base32 alphabet
    #expect(Base32.decode("MZXW0YTB") == nil)  // neither is '0'
  }
}
