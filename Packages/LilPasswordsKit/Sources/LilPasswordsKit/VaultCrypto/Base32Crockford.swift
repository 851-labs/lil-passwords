import Foundation

/// Crockford's Base32: a human-friendly Base32 variant that excludes the visually ambiguous
/// letters `I`, `L`, `O`, and `U`, and is case-insensitive on decode.
///
/// See <https://www.crockford.com/base32.html>. Used here to render recovery keys as text a
/// person can write down and type back in without much room for error.
enum Base32Crockford {
  private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
  private static let decodeMap: [Character: UInt8] = {
    var map: [Character: UInt8] = [:]
    for (index, character) in alphabet.enumerated() {
      map[character] = UInt8(index)
    }
    return map
  }()

  /// Encodes `data` as an unpadded, uppercase Crockford Base32 string.
  static func encode(_ data: Data) -> String {
    guard !data.isEmpty else { return "" }

    var bitBuffer: UInt64 = 0
    var bitCount = 0
    var output = ""
    output.reserveCapacity((data.count * 8 + 4) / 5)

    for byte in data {
      bitBuffer = (bitBuffer << 8) | UInt64(byte)
      bitCount += 8
      while bitCount >= 5 {
        bitCount -= 5
        let index = Int((bitBuffer >> UInt64(bitCount)) & 0x1F)
        output.append(alphabet[index])
      }
    }
    if bitCount > 0 {
      let index = Int((bitBuffer << UInt64(5 - bitCount)) & 0x1F)
      output.append(alphabet[index])
    }
    return output
  }

  /// Decodes a Crockford Base32 string.
  ///
  /// Case-insensitive; ignores dashes and whitespace; leniently maps the letters `O`, `I`, and
  /// `L` to `0`, `1`, and `1` respectively, per the spec's guidance for human-entered input.
  /// Returns `nil` on any character outside the alphabet, or if the leftover bits after the
  /// last full byte aren't zero (which would mean the string isn't a valid encoding of any
  /// byte sequence).
  static func decode(_ string: String) -> Data? {
    var bitBuffer: UInt64 = 0
    var bitCount = 0
    var output = [UInt8]()
    output.reserveCapacity(string.count * 5 / 8)

    for rawCharacter in string {
      if rawCharacter == "-" || rawCharacter.isWhitespace { continue }
      guard let value = decodeMap[normalize(rawCharacter)] else { return nil }
      bitBuffer = (bitBuffer << 5) | UInt64(value)
      bitCount += 5
      if bitCount >= 8 {
        bitCount -= 8
        output.append(UInt8((bitBuffer >> UInt64(bitCount)) & 0xFF))
      }
    }

    // Any leftover bits must be padding zero bits, not real data.
    if bitCount > 0, (bitBuffer & ((1 << UInt64(bitCount)) - 1)) != 0 {
      return nil
    }

    return Data(output)
  }

  private static func normalize(_ character: Character) -> Character {
    let upper = Character(character.uppercased())
    switch upper {
    case "O": return "0"
    case "I", "L": return "1"
    default: return upper
    }
  }
}
