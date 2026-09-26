import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct CSVParserTests {
  @Test func parsesSimpleRows() throws {
    let rows = try CSVParser.parse("a,b,c\n1,2,3\n")
    #expect(rows == [["a", "b", "c"], ["1", "2", "3"]])
  }

  @Test func handlesCRLFLineEndings() throws {
    let rows = try CSVParser.parse("a,b\r\n1,2\r\n")
    #expect(rows == [["a", "b"], ["1", "2"]])
  }

  @Test func handlesBareLFAndCRLFMixedInSameFile() throws {
    let rows = try CSVParser.parse("a,b\r\n1,2\n3,4\r\n")
    #expect(rows == [["a", "b"], ["1", "2"], ["3", "4"]])
  }

  @Test func stripsLeadingUTF8BOM() throws {
    let rows = try CSVParser.parse("\u{FEFF}a,b\n1,2\n")
    #expect(rows == [["a", "b"], ["1", "2"]])
  }

  @Test func quotedFieldCanContainCommas() throws {
    let rows = try CSVParser.parse(#"name,note\#n"Doe, Jane","hi, there"\#n"#)
    #expect(rows == [["name", "note"], ["Doe, Jane", "hi, there"]])
  }

  @Test func quotedFieldCanContainEmbeddedNewlines() throws {
    let rows = try CSVParser.parse("notes\n\"line one\nline two\"\n")
    #expect(rows == [["notes"], ["line one\nline two"]])
  }

  @Test func doubledQuoteInsideQuotedFieldIsAnEscapedQuote() throws {
    let rows = try CSVParser.parse(#"title\#n"She said ""hi"""\#n"#)
    #expect(rows == [["title"], [#"She said "hi""#]])
  }

  @Test func emptyFieldsRoundTrip() throws {
    let rows = try CSVParser.parse("a,b,c\n1,,3\n")
    #expect(rows == [["a", "b", "c"], ["1", "", "3"]])
  }

  @Test func trailingNewlineDoesNotProduceAPhantomRow() throws {
    let rows = try CSVParser.parse("a,b\n1,2\n")
    #expect(rows.count == 2)
  }

  @Test func missingTrailingNewlineStillParsesLastRow() throws {
    let rows = try CSVParser.parse("a,b\n1,2")
    #expect(rows == [["a", "b"], ["1", "2"]])
  }

  @Test func unterminatedQuotedFieldThrows() {
    #expect(throws: CSVParsingError.unterminatedQuotedField) {
      try CSVParser.parse("title\n\"never closed\n")
    }
  }

  @Test func parsesDataStrippingUTF8BOMBytes() throws {
    let data = Data([0xEF, 0xBB, 0xBF]) + Data("a,b\n1,2\n".utf8)
    let rows = try CSVParser.parse(data: data)
    #expect(rows == [["a", "b"], ["1", "2"]])
  }

  @Test func invalidUTF8DataThrows() {
    let data = Data([0xFF, 0xFE, 0x00])
    #expect(throws: CSVParsingError.invalidEncoding) {
      try CSVParser.parse(data: data)
    }
  }

  @Test func fixtureFileWithBOMCRLFAndQuotingParsesToExpectedRowCount() throws {
    let url = try Fixture.url("apple_passwords")
    let text = try String(contentsOf: url, encoding: .utf8)
    let rows = try CSVParser.parse(text)
    // header + 3 data rows
    #expect(rows.count == 4)
    #expect(rows[0] == ["Title", "URL", "Username", "Password", "Notes", "OTPAuth"])
    #expect(rows[3][0] == "Quoted \"Value\" Site")
    #expect(rows[3][3] == "pa\"ss")
  }

  @Test func malformedFixtureThrowsUnterminatedQuotedField() throws {
    let url = try Fixture.url("malformed_unterminated_quote")
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(throws: CSVParsingError.unterminatedQuotedField) {
      try CSVParser.parse(text)
    }
  }
}
