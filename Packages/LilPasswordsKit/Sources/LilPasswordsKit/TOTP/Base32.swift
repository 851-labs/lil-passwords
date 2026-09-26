import Foundation

/// RFC 4648 base32 encoding, used for TOTP shared secrets in `otpauth://` URIs and by
/// authenticator apps' manual-entry codes.
public enum Base32 {
  private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

  private static let decodeTable: [Int8] = {
    var table = [Int8](repeating: -1, count: 128)
    for (index, character) in alphabet.enumerated() {
      table[Int(character)] = Int8(index)
    }
    return table
  }()

  /// Encodes `data` as an uppercase base32 string.
  ///
  /// - Parameter padded: Whether to pad the result with `=` to a multiple of 8 characters, per
  ///   RFC 4648. Most `otpauth://` URIs and authenticator apps omit padding. Defaults to `false`.
  public static func encode(_ data: Data, padded: Bool = false) -> String {
    guard !data.isEmpty else { return "" }

    var output = [UInt8]()
    output.reserveCapacity((data.count * 8 + 4) / 5)

    var buffer: UInt32 = 0
    var bitsInBuffer = 0

    for byte in data {
      buffer = (buffer << 8) | UInt32(byte)
      bitsInBuffer += 8
      while bitsInBuffer >= 5 {
        bitsInBuffer -= 5
        output.append(alphabet[Int((buffer >> UInt32(bitsInBuffer)) & 0x1f)])
      }
    }

    if bitsInBuffer > 0 {
      output.append(alphabet[Int((buffer << UInt32(5 - bitsInBuffer)) & 0x1f)])
    }

    if padded {
      let remainder = output.count % 8
      if remainder != 0 {
        output.append(contentsOf: repeatElement(UInt8(ascii: "="), count: 8 - remainder))
      }
    }

    return String(decoding: output, as: UTF8.self)
  }

  /// Decodes a base32 string.
  ///
  /// Accepts upper or lower case, tolerates interior spaces and dashes (many authenticator apps
  /// display secrets in groups of four), and optional `=` padding. Returns `nil` if the string
  /// contains characters outside the base32 alphabet.
  public static func decode(_ string: String) -> Data? {
    var buffer: UInt32 = 0
    var bitsInBuffer = 0
    var output = [UInt8]()
    output.reserveCapacity(string.count * 5 / 8)

    for scalar in string.unicodeScalars {
      switch scalar {
      case " ", "-", "=":
        continue
      default:
        break
      }

      var value = scalar.value
      if value >= 97, value <= 122 { value -= 32 }  // fold a-z to A-Z
      guard value < 128, decodeTable[Int(value)] >= 0 else { return nil }

      buffer = (buffer << 5) | UInt32(decodeTable[Int(value)])
      bitsInBuffer += 5
      if bitsInBuffer >= 8 {
        bitsInBuffer -= 8
        output.append(UInt8((buffer >> UInt32(bitsInBuffer)) & 0xff))
      }
    }

    return Data(output)
  }
}
