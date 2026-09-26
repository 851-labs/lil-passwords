import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct CSVExporterTests {
  @Test func csvTextWritesTheHeaderRow() {
    let text = CSVExporter.csvText(for: [])
    #expect(text == "Title,URL,Username,Password,Notes,OTPAuth\r\n")
  }

  @Test func csvTextWritesOneRowPerItem() throws {
    let item = PasswordItem(
      title: "Acme Corp",
      usernames: ["alice@example.com"],
      password: "correct horse battery staple",
      websites: [URL(string: "https://acme.example.com")!],
      notes: "plain notes",
      totpURI: "otpauth://totp/Acme:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Acme"
    )

    let text = CSVExporter.csvText(for: [item])
    let rows = try CSVParser.parse(text)
    #expect(rows.count == 2)
    #expect(
      rows[1] == [
        "Acme Corp",
        "https://acme.example.com",
        "alice@example.com",
        "correct horse battery staple",
        "plain notes",
        "otpauth://totp/Acme:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Acme",
      ])
  }

  @Test func csvTextQuotesFieldsWithCommasQuotesAndNewlines() throws {
    let item = PasswordItem(
      title: "Quoted \"Value\" Site",
      usernames: ["bob"],
      password: "pa\"ss",
      notes: "line one,\nline two"
    )

    let text = CSVExporter.csvText(for: [item])
    let rows = try CSVParser.parse(text)
    #expect(rows[1][0] == "Quoted \"Value\" Site")
    #expect(rows[1][3] == "pa\"ss")
    #expect(rows[1][4] == "line one,\nline two")
  }

  @Test func csvTextOmitsDeletedItems() {
    let active = PasswordItem(title: "Active", usernames: [], password: "p")
    var deleted = PasswordItem(title: "Deleted", usernames: [], password: "p")
    deleted.deletedAt = Date()

    let text = CSVExporter.csvText(for: [active, deleted])
    #expect(text.contains("Active"))
    #expect(!text.contains("Deleted"))
  }

  @Test func csvTextWritesOnlyTheFirstWebsiteAndUsername() throws {
    let item = PasswordItem(
      title: "Multi",
      usernames: ["primary", "secondary"],
      password: "p",
      websites: [URL(string: "https://first.example.com")!, URL(string: "https://second.example.com")!]
    )

    let rows = try CSVParser.parse(CSVExporter.csvText(for: [item]))
    #expect(rows[1][1] == "https://first.example.com")
    #expect(rows[1][2] == "primary")
  }

  @Test func csvTextLeavesEmptyFieldsBlank() throws {
    let item = PasswordItem(title: "Bare", usernames: [], password: "")
    let rows = try CSVParser.parse(CSVExporter.csvText(for: [item]))
    #expect(rows[1] == ["Bare", "", "", "", "", ""])
  }

  @Test func exportRoundTripsThroughTheImporter() throws {
    let items = [
      PasswordItem(
        title: "Acme Corp",
        usernames: ["alice@example.com"],
        password: "correct horse battery staple",
        websites: [URL(string: "https://acme.example.com")!],
        notes: "Multi-line note,\nwith a comma and a newline",
        totpURI: "otpauth://totp/Acme:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Acme"
      ),
      PasswordItem(title: "GitHub", usernames: ["octocat"], password: "ghp_dummyToken1234567890"),
      PasswordItem(
        title: "Quoted \"Value\" Site",
        usernames: ["bob"],
        password: "pa\"ss",
        notes: "She said \"hello\""
      ),
    ]

    let exported = CSVExporter.csvText(for: items)
    let format = try CSVImporter.detectFormat(exported)
    #expect(format == .applePasswords)

    let result = try CSVImporter.importCSV(exported)
    #expect(result.credentials.count == items.count)

    for (original, imported) in zip(items, result.credentials) {
      #expect(imported.title == original.title)
      #expect(imported.username == (original.usernames.first ?? ""))
      #expect(imported.password == original.password)
      #expect(imported.urls == original.websites.map(\.absoluteString))
      #expect(imported.notes == (original.notes.isEmpty ? nil : original.notes))
      #expect(imported.otpAuth == original.totpURI)
    }
  }

  @Test func writeCreatesAFileWithOwnerOnlyPermissions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("export.csv")
    let items = [PasswordItem(title: "Acme", usernames: ["alice"], password: "p")]
    try CSVExporter.write(items, to: url)

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.uint16Value == 0o600)

    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(try CSVImporter.importCSV(text).credentials.count == 1)
  }

  @Test func writeOverwritesAnExistingFileAndKeepsRestrictedPermissions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("export.csv")
    try "stale contents".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

    try CSVExporter.write([PasswordItem(title: "Fresh", usernames: [], password: "p")], to: url)

    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("Fresh"))
    #expect(!text.contains("stale contents"))

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.uint16Value == 0o600)
  }
}
