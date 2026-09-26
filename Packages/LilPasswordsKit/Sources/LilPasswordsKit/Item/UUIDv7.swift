import Foundation

extension UUID {
  /// Generates a UUID version 7 (RFC 9562 §5.7): a 48-bit big-endian Unix millisecond
  /// timestamp in the most significant bits, followed by 74 bits of randomness (12 bits of
  /// `rand_a`, then 62 bits of `rand_b`, split by the version and variant bits per the RFC's
  /// layout).
  ///
  /// Unlike the random-only `UUID()` (version 4), a v7 id sorts roughly by creation time. This
  /// is why `PasswordItem.id` uses it: a future sync layer, or `VaultStore` itself, can lean on
  /// the id's own ordering as a cheap approximation of creation order, without a separate
  /// `createdAt` index or leaking a *sequential* insertion order the way an auto-incrementing
  /// integer id would.
  ///
  /// - Parameters:
  ///   - date: The timestamp to encode in the id's leading 48 bits. Defaults to now.
  ///   - randomBytes: Exactly 10 bytes of randomness for the non-timestamp bits. Defaults to a
  ///     fresh draw from the system CSPRNG; overridable so tests can assert the exact bit
  ///     layout deterministically.
  public static func v7(date: Date = Date(), randomBytes: Data? = nil) -> UUID {
    let randomBytes = randomBytes ?? SecureRandom.bytes(10)
    precondition(randomBytes.count == 10, "UUID.v7 needs exactly 10 random bytes, got \(randomBytes.count)")
    let random = [UInt8](randomBytes)

    let millis = UInt64(max(0, date.timeIntervalSince1970) * 1000)
    var bytes = [UInt8](repeating: 0, count: 16)
    bytes[0] = UInt8((millis >> 40) & 0xFF)
    bytes[1] = UInt8((millis >> 32) & 0xFF)
    bytes[2] = UInt8((millis >> 24) & 0xFF)
    bytes[3] = UInt8((millis >> 16) & 0xFF)
    bytes[4] = UInt8((millis >> 8) & 0xFF)
    bytes[5] = UInt8(millis & 0xFF)

    // Byte 6: version (0111) in the high nibble, the top 4 bits of `rand_a` in the low nibble.
    bytes[6] = 0x70 | (random[0] & 0x0F)
    // Byte 7: the remaining 8 bits of `rand_a` (12 bits total).
    bytes[7] = random[1]

    // Byte 8: variant (10) in the top 2 bits, the top 6 bits of `rand_b` in the rest.
    bytes[8] = 0x80 | (random[2] & 0x3F)
    // Bytes 9-15: the remaining 56 bits of `rand_b` (62 bits total).
    bytes[9] = random[3]
    bytes[10] = random[4]
    bytes[11] = random[5]
    bytes[12] = random[6]
    bytes[13] = random[7]
    bytes[14] = random[8]
    bytes[15] = random[9]

    let uuid = bytes.withUnsafeBytes { $0.load(as: uuid_t.self) }
    return UUID(uuid: uuid)
  }
}
