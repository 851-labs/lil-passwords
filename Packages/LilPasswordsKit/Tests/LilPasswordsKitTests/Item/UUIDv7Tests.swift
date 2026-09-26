import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct UUIDv7Tests {
  @Test func setsTheVersionAndVariantBits() {
    let uuid = UUID.v7()
    let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }

    // Version 7 lives in the high nibble of byte 6.
    #expect(bytes[6] & 0xF0 == 0x70)
    // RFC 4122 variant "10" lives in the top two bits of byte 8.
    #expect(bytes[8] & 0xC0 == 0x80)
  }

  @Test func encodesTheGivenTimestampInTheLeading48Bits() {
    let date = Date(timeIntervalSince1970: 1_700_000_000.123)
    let uuid = UUID.v7(date: date, randomBytes: Data(repeating: 0, count: 10))
    let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }

    let expectedMillis = UInt64(date.timeIntervalSince1970 * 1000)
    let encodedMillis =
      (UInt64(bytes[0]) << 40) | (UInt64(bytes[1]) << 32) | (UInt64(bytes[2]) << 24) | (UInt64(bytes[3]) << 16)
      | (UInt64(bytes[4]) << 8) | UInt64(bytes[5])

    #expect(encodedMillis == expectedMillis)
  }

  @Test func usesEveryByteOfTheSuppliedRandomness() {
    let random = Data((0..<10).map { UInt8($0 + 1) })
    let uuid = UUID.v7(date: Date(timeIntervalSince1970: 0), randomBytes: random)
    let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }

    #expect(bytes[6] & 0x0F == random[0] & 0x0F)
    #expect(bytes[7] == random[1])
    #expect(bytes[8] & 0x3F == random[2] & 0x3F)
    #expect(bytes[9] == random[3])
    #expect(bytes[15] == random[9])
  }

  @Test func sortsRoughlyByCreationTime() {
    let earlier = Date(timeIntervalSince1970: 1_700_000_000)
    let later = earlier.addingTimeInterval(5)
    let random = Data(repeating: 0x42, count: 10)

    let earlierUUID = UUID.v7(date: earlier, randomBytes: random)
    let laterUUID = UUID.v7(date: later, randomBytes: random)

    // Same random suffix on both sides means only the timestamp bits differ, so a plain
    // lexicographic string comparison reduces to a timestamp comparison.
    #expect(earlierUUID.uuidString < laterUUID.uuidString)
  }

  @Test func generatesUniqueIdsForTheSameInstant() {
    let date = Date()
    let first = UUID.v7(date: date)
    let second = UUID.v7(date: date)

    #expect(first != second)
  }
}
