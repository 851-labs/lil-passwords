import AppKit
import Foundation
import PDFKit
import Testing

@testable import LilPasswordsKit

@Suite struct RecoveryKitDocumentTests {
  private func makeContent(
    appName: String = "Lil Passwords",
    displayKey: String = VaultCrypto.RecoveryKey.generate().displayString,
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) -> RecoveryKitDocument.Content {
    RecoveryKitDocument.Content(appName: appName, displayKey: displayKey, createdAt: createdAt)
  }

  @Test func renderPDFProducesAValidSinglePagePDF() throws {
    let content = makeContent()
    let data = RecoveryKitDocument.renderPDF(content)

    #expect(!data.isEmpty)
    let document = try #require(PDFDocument(data: data))
    #expect(document.pageCount == 1)
  }

  @Test func renderedPageIncludesTheAppNameAndRecoveryKey() throws {
    let content = makeContent(appName: "Lil Passwords", displayKey: "4S9K-D2XQ-7RTN-VBWC-XM3P")
    let data = RecoveryKitDocument.renderPDF(content)

    let document = try #require(PDFDocument(data: data))
    let page = try #require(document.page(at: 0))
    let text = try #require(page.string)

    #expect(text.contains("Lil Passwords"))
    #expect(text.contains("4S9K-D2XQ-7RTN-VBWC-XM3P"))
    // The plain-English "anyone with this key and your vault file" warning the ticket asks for.
    #expect(text.localizedCaseInsensitiveContains("vault file"))
  }

  @Test func renderPDFProducesDeterministicTextForTheSameContent() throws {
    let content = makeContent()
    let first = try #require(PDFDocument(data: RecoveryKitDocument.renderPDF(content)))
    let second = try #require(PDFDocument(data: RecoveryKitDocument.renderPDF(content)))

    #expect(first.page(at: 0)?.string == second.page(at: 0)?.string)
  }

  @Test func renderFirstPagePNGProducesANonEmptyImageAtTheRequestedWidth() throws {
    let data = RecoveryKitDocument.renderPDF(makeContent())
    let png = try #require(RecoveryKitDocument.renderFirstPagePNG(from: data, width: 300))

    #expect(!png.isEmpty)
    let bitmap = try #require(NSBitmapImageRep(data: png))
    #expect(bitmap.pixelsWide == 300)
    #expect(bitmap.pixelsHigh > 0)
  }

  @Test func renderFirstPagePNGRejectsInvalidPDFData() {
    #expect(RecoveryKitDocument.renderFirstPagePNG(from: Data("not a pdf".utf8)) == nil)
  }
}
