import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct CSVImporterTests {
  @Test func detectsApplePasswordsFormat() throws {
    let format = try CSVImporter.detectFormat(Fixture.text("apple_passwords"))
    #expect(format == .applePasswords)
  }

  @Test func detectsSafariFormatEvenWithoutOTPAuthColumn() throws {
    let format = try CSVImporter.detectFormat(Fixture.text("safari_no_otp_column"))
    #expect(format == .applePasswords)
  }

  @Test func detectsChromeFormat() throws {
    let format = try CSVImporter.detectFormat(Fixture.text("chrome"))
    #expect(format == .chrome)
  }

  @Test func detects1PasswordFormat() throws {
    let format = try CSVImporter.detectFormat(Fixture.text("one_password"))
    #expect(format == .onePassword)
  }

  @Test func detectsBitwardenFormat() throws {
    let format = try CSVImporter.detectFormat(Fixture.text("bitwarden"))
    #expect(format == .bitwarden)
  }

  @Test func unrecognizedHeadersThrow() {
    #expect(throws: CSVImporter.ImportError.self) {
      try CSVImporter.importCSV("foo,bar\n1,2\n")
    }
  }

  @Test func emptyFileThrows() {
    #expect(throws: CSVImporter.ImportError.emptyFile) {
      try CSVImporter.importCSV("")
    }
    #expect(throws: CSVImporter.ImportError.emptyFile) {
      try CSVImporter.importCSV("\n\n")
    }
  }

  @Test func importsApplePasswordsFixture() throws {
    let result = try CSVImporter.importCSV(Fixture.text("apple_passwords"))
    #expect(result.format == .applePasswords)
    #expect(result.credentials.count == 3)
    #expect(result.skippedRowCount == 0)

    let acme = try #require(result.credentials.first { $0.title == "Acme Corp" })
    #expect(acme.username == "alice@example.com")
    #expect(acme.password == "correct horse battery staple")
    #expect(acme.urls == ["https://acme.example.com"])
    #expect(acme.notes == "Multi-line note,\nwith a comma and a newline")
    #expect(acme.otpAuth == "otpauth://totp/Acme:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Acme")

    let github = try #require(result.credentials.first { $0.title == "GitHub" })
    #expect(github.notes == nil)
    #expect(github.otpAuth == nil)

    let quoted = try #require(result.credentials.first { $0.username == "bob" })
    #expect(quoted.title == "Quoted \"Value\" Site")
    #expect(quoted.password == "pa\"ss")
    #expect(quoted.notes == "She said \"hello\"")
  }

  @Test func importsChromeFixture() throws {
    let result = try CSVImporter.importCSV(Fixture.text("chrome"))
    #expect(result.format == .chrome)
    #expect(result.credentials.count == 2)

    let streaming = try #require(result.credentials.first { $0.title == "Streaming Co" })
    #expect(streaming.username == "dave@example.com")
    #expect(streaming.password == "p@ssw0rd,with,commas")
    #expect(streaming.notes == "shared with family, don't change")
    #expect(streaming.otpAuth == nil)
  }

  @Test func imports1PasswordFixture() throws {
    let result = try CSVImporter.importCSV(Fixture.text("one_password"))
    #expect(result.format == .onePassword)
    #expect(result.credentials.count == 2)

    let acme = try #require(result.credentials.first { $0.title == "Acme Corp" })
    #expect(acme.otpAuth == "otpauth://totp/Acme:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Acme")

    let wiki = try #require(result.credentials.first { $0.title == "Internal Wiki" })
    #expect(wiki.otpAuth == nil)
    #expect(wiki.notes == "team wiki")
  }

  @Test func importsBitwardenFixtureAndSkipsNonLoginRows() throws {
    let result = try CSVImporter.importCSV(Fixture.text("bitwarden"))
    #expect(result.format == .bitwarden)
    #expect(result.credentials.count == 2)
    #expect(result.skippedRowCount == 1)  // the "Wifi password" secure note

    let social = try #require(result.credentials.first { $0.title == "Example Social" })
    #expect(social.username == "erin@example.com")
    #expect(social.urls == ["https://example.com", "https://m.example.com"])
    #expect(social.otpAuth == "otpauth://totp/Example:erin@example.com?secret=ABCDEFGHIJKLMNOP&issuer=Example")

    let intranet = try #require(result.credentials.first { $0.title == "Intranet" })
    #expect(intranet.username == "erin")
    #expect(intranet.urls == ["https://intranet.example.com"])
    #expect(intranet.otpAuth == nil)
  }

  @Test func importCSVDataOverloadMatchesTextOverload() throws {
    let text = try Fixture.text("chrome")
    let result = try CSVImporter.importCSV(data: Data(text.utf8))
    #expect(result.format == .chrome)
    #expect(result.credentials.count == 2)
  }
}
