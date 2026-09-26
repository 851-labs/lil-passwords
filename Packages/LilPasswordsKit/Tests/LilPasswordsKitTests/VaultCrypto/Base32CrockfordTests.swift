import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct Base32CrockfordTests {
  @Test func encodesAndDecodesEmptyData() {
    #expect(Base32Crockford.encode(Data()) == "")
    #expect(Base32Crockford.decode("") == Data())
  }

  @Test(arguments: [0, 1, 4, 5, 9, 16, 20, 21, 32])
  func roundTripsRandomDataOfVariousLengths(byteCount: Int) throws {
    let data = Data((0..<byteCount).map { UInt8($0 * 7 % 256) })

    let encoded = Base32Crockford.encode(data)
    let decoded = try #require(Base32Crockford.decode(encoded))

    #expect(decoded == data)
  }

  @Test func decodeIsCaseInsensitiveAndIgnoresDashesAndWhitespace() {
    let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
    let encoded = Base32Crockford.encode(data)

    let messy = " " + encoded.lowercased().map { String($0) }.joined(separator: "-") + " "

    #expect(Base32Crockford.decode(messy) == data)
  }

  @Test func decodeMapsLookalikeLettersLikeTheSpecRecommends() {
    // "O" -> "0", "I"/"L" -> "1".
    #expect(Base32Crockford.decode("O") == Base32Crockford.decode("0"))
    #expect(Base32Crockford.decode("I") == Base32Crockford.decode("1"))
    #expect(Base32Crockford.decode("L") == Base32Crockford.decode("1"))
  }

  @Test func decodeRejectsCharactersOutsideTheAlphabet() {
    #expect(Base32Crockford.decode("!") == nil)
    #expect(Base32Crockford.decode("U") == nil)  // Excluded by the Crockford alphabet.
  }
}

@Suite struct CRC8Tests {
  @Test func isDeterministic() {
    let data: [UInt8] = [1, 2, 3, 4, 5]
    #expect(CRC8.checksum(data) == CRC8.checksum(data))
  }

  @Test func detectsASingleBitFlip() {
    let original: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
    var flipped = original
    flipped[3] ^= 0x01

    #expect(CRC8.checksum(original) != CRC8.checksum(flipped))
  }
}
