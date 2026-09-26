import CoreGraphics
import CoreImage
import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct QRCodeReaderTests {
  /// Renders `string` into an in-memory QR code image, so tests don't depend on a fixture file.
  private func renderQRCode(_ string: String) throws -> CGImage {
    let filter = try #require(CIFilter(name: "CIQRCodeGenerator"))
    filter.setValue(Data(string.utf8), forKey: "inputMessage")
    filter.setValue("H", forKey: "inputCorrectionLevel")

    let outputImage = try #require(filter.outputImage)
    // The generator produces one pixel per module; scale up so the detector has enough
    // resolution to read it back reliably.
    let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))

    let context = CIContext()
    return try #require(context.createCGImage(scaled, from: scaled.extent))
  }

  @Test func decodesAPlainQRCode() throws {
    let image = try renderQRCode("hello lil passwords")
    #expect(QRCodeReader.decode(image) == ["hello lil passwords"])
  }

  @Test func decodesAnOTPAuthQRCode() throws {
    let uri =
      "otpauth://totp/Acme:alex@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Acme&algorithm=SHA1&digits=6&period=30"
    let image = try renderQRCode(uri)

    let results = QRCodeReader.decodeOTPAuthURIs(from: image)
    #expect(results.count == 1)
    #expect(results.first?.issuer == "Acme")
    #expect(results.first?.accountName == "alex@example.com")
  }

  @Test func returnsEmptyForAnImageWithNoQRCode() throws {
    let context = CIContext()
    let blank = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
    let image = try #require(context.createCGImage(blank, from: blank.extent))

    #expect(QRCodeReader.decode(image).isEmpty)
  }
}
