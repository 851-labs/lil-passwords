import CoreGraphics
import CoreImage
import Foundation

/// Decodes QR codes from an image, so the app can import a TOTP secret from an image file, a
/// pasted clipboard image, or a screenshot.
public enum QRCodeReader {
  /// Returns the raw text payload of every QR code found in `image`, in the order Core Image
  /// reports them.
  public static func decode(_ image: CGImage) -> [String] {
    guard
      let detector = CIDetector(
        ofType: CIDetectorTypeQRCode,
        context: nil,
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
      )
    else {
      return []
    }

    let features = detector.features(in: CIImage(cgImage: image))
    return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
  }

  /// Returns every `otpauth://` URI found in `image`, already parsed. QR payloads that aren't a
  /// valid `otpauth://totp/...` URI (e.g. a link to a website) are silently skipped.
  public static func decodeOTPAuthURIs(from image: CGImage) -> [OTPAuthURI] {
    decode(image).compactMap { payload in
      guard let url = URL(string: payload) else { return nil }
      return try? OTPAuthURI(url: url)
    }
  }
}
