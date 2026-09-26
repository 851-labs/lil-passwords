import Foundation

/// A minimal, write-only CBOR (RFC 8949) encoder — just enough to build the two fixed shapes
/// WebAuthn needs (a COSE_Key map and a "none"-format attestation object), not a general-purpose
/// CBOR library. Every `append*` function writes in canonical-CBOR order (definite lengths,
/// shortest-form integers), so the handful of maps ``PasskeyAuthenticator`` builds are byte-for-byte
/// what a conformant WebAuthn relying party expects to parse.
enum CBOR {
  /// Writes a CBOR item header: the major type (top 3 bits) and length/argument, using the
  /// shortest encoding for `length` per RFC 8949 §3.1's canonical form (direct 0–23, else the
  /// smallest of 1/2/4/8 trailing bytes).
  static func appendHeader(majorType: UInt8, length: UInt64, to data: inout Data) {
    let typeBits = majorType << 5
    switch length {
    case 0..<24:
      data.append(typeBits | UInt8(length))
    case 24...0xFF:
      data.append(typeBits | 24)
      data.append(UInt8(length))
    case 0x100...0xFFFF:
      data.append(typeBits | 25)
      var value = UInt16(length).bigEndian
      withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    case 0x1_0000...0xFFFF_FFFF:
      data.append(typeBits | 26)
      var value = UInt32(length).bigEndian
      withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    default:
      data.append(typeBits | 27)
      var value = length.bigEndian
      withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
  }

  /// A signed integer: major type 0 (unsigned) for `value >= 0`, major type 1 (negative, encoding
  /// `-1-value` per RFC 8949 §3.1) for `value < 0` — covers every integer a COSE_Key or its
  /// wrapping attestation object ever needs (key type/algorithm/curve identifiers, coordinates'
  /// lengths).
  static func appendInt(_ value: Int, to data: inout Data) {
    if value >= 0 {
      appendHeader(majorType: 0, length: UInt64(value), to: &data)
    } else {
      appendHeader(majorType: 1, length: UInt64(-1 - value), to: &data)
    }
  }

  /// A CBOR byte string (major type 2): header plus raw bytes, no escaping.
  static func appendByteString(_ bytes: Data, to data: inout Data) {
    appendHeader(majorType: 2, length: UInt64(bytes.count), to: &data)
    data.append(bytes)
  }

  /// A CBOR UTF-8 text string (major type 3): header plus UTF-8 bytes.
  static func appendTextString(_ string: String, to data: inout Data) {
    let utf8 = Data(string.utf8)
    appendHeader(majorType: 3, length: UInt64(utf8.count), to: &data)
    data.append(utf8)
  }

  /// A definite-length map header (major type 5) for `count` key/value pairs. Callers append the
  /// `2 * count` key/value items themselves, immediately after.
  static func appendMapHeader(count: Int, to data: inout Data) {
    appendHeader(majorType: 5, length: UInt64(count), to: &data)
  }
}
