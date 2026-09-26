import Foundation

/// A tiny CRC-8 (polynomial `0x07`) used as a typo-detecting checksum on recovery keys.
///
/// This is not a cryptographic primitive — it exists only to catch accidental transcription
/// mistakes when a human copies a recovery key by hand, the same role a check digit plays on
/// a credit card or IBAN.
enum CRC8 {
  static func checksum(_ bytes: some Sequence<UInt8>) -> UInt8 {
    var crc: UInt8 = 0
    for byte in bytes {
      crc ^= byte
      for _ in 0..<8 {
        crc = (crc & 0x80) != 0 ? (crc << 1) ^ 0x07 : crc << 1
      }
    }
    return crc
  }
}
