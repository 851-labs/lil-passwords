import CryptoKit
import Foundation

/// WebAuthn authenticator-side operations lil passwords performs for a `PasskeyItem` (851-2442):
/// building `authenticatorData`, a "none"-format attestation object for registration, and signing
/// an assertion.
///
/// Pure functions over `Data`/`CryptoKit` types — no vault, XPC, or `AgentServer` awareness — so
/// they're directly unit-testable and are the one place in this ticket that has to get WebAuthn's
/// wire format right. Nothing here decides *whether* signing is allowed: `AgentServer` (caller
/// identity, write-access gating) decides that before ever calling in, and only `AgentServer`
/// (via `VaultStoreCore`'s decrypted `PasskeyItem` index) ever holds the private key these
/// functions sign with — see `PasskeyItem.privateKeyPKCS8`'s documentation.
///
/// See the WebAuthn Level 2 spec: §6.1 (authenticator data), §6.5.4 ("none" attestation
/// statement format), §6.5.2 (attested credential data), §6.3.3 (assertion signature base).
enum PasskeyAuthenticator {
  /// The AAGUID lil passwords reports in `attestedCredentialData`: all-zero, the conventional
  /// value for an authenticator that doesn't identify a specific make/model — consistent with
  /// registering under the "none" attestation format, which makes no claim about provenance at
  /// all.
  static let aaguid = Data(repeating: 0, count: 16)

  /// The `flags` byte's bit positions (WebAuthn §6.1, Table 4).
  private enum Flag {
    static let userPresent: UInt8 = 0x01
    static let userVerified: UInt8 = 0x04
    static let attestedCredentialDataIncluded: UInt8 = 0x40
  }

  /// Builds `authenticatorData` (§6.1): `rpIdHash ‖ flags ‖ signCount [‖ attestedCredentialData]`.
  ///
  /// - Parameters:
  ///   - relyingPartyIdentifier: SHA-256 hashed to produce the leading 32-byte `rpIdHash`.
  ///   - userPresent: The UP flag. lil passwords always sets this: by the time this is called,
  ///     the helper is unlocked and the caller (AutoFill, having shown its own Unlock UI, or the
  ///     app) has already established the user is present.
  ///   - userVerified: The UV flag. Also always set, for the same reason — there's no separate
  ///     PIN/biometric ceremony beyond the helper's own unlock.
  ///   - signCount: Encoded big-endian into the 4-byte counter (§6.1: "signed 32-bit unsigned
  ///     integer" — this project's `PasskeyItem.signCount` is already `UInt32`).
  ///   - attestedCredentialData: Present only for registration, which sets the AT flag (bit 6);
  ///     `nil` for an assertion, which must not set it (§6.1).
  static func authenticatorData(
    relyingPartyIdentifier: String,
    userPresent: Bool = true,
    userVerified: Bool = true,
    signCount: UInt32,
    attestedCredentialData: Data? = nil
  ) -> Data {
    var data = Data(SHA256.hash(data: Data(relyingPartyIdentifier.utf8)))

    var flags: UInt8 = 0
    if userPresent { flags |= Flag.userPresent }
    if userVerified { flags |= Flag.userVerified }
    if attestedCredentialData != nil { flags |= Flag.attestedCredentialDataIncluded }
    data.append(flags)

    var signCountBE = signCount.bigEndian
    withUnsafeBytes(of: &signCountBE) { data.append(contentsOf: $0) }

    if let attestedCredentialData {
      data.append(attestedCredentialData)
    }
    return data
  }

  /// Builds `attestedCredentialData` (§6.5.2): `aaguid ‖ credentialIdLength(2 bytes, BE) ‖
  /// credentialId ‖ credentialPublicKey` (the COSE_Key encoding from ``coseKey(for:)``).
  static func attestedCredentialData(credentialId: Data, publicKey: P256.Signing.PublicKey) -> Data {
    var data = aaguid
    var length = UInt16(credentialId.count).bigEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(credentialId)
    data.append(coseKey(for: publicKey))
    return data
  }

  /// The COSE_Key encoding (RFC 9053 §7.1.1) of an ES256 (P-256/SHA-256) public key: a 5-entry
  /// CBOR map — key type EC2 (2), algorithm ES256 (-7), curve P-256 (1), and the two
  /// uncompressed-point coordinates, each 32 bytes.
  ///
  /// `P256.Signing.PublicKey.x963Representation` is ANSI X9.63 uncompressed-point format:
  /// `0x04 ‖ x(32) ‖ y(32)` — the leading `0x04` is stripped before encoding, since COSE_Key
  /// stores `x`/`y` as separate byte strings rather than an X9.63 blob.
  static func coseKey(for publicKey: P256.Signing.PublicKey) -> Data {
    let point = publicKey.x963Representation
    let x = point.subdata(in: 1..<33)
    let y = point.subdata(in: 33..<65)

    var cbor = Data()
    CBOR.appendMapHeader(count: 5, to: &cbor)
    CBOR.appendInt(1, to: &cbor)  // kty
    CBOR.appendInt(2, to: &cbor)  // EC2
    CBOR.appendInt(3, to: &cbor)  // alg
    CBOR.appendInt(-7, to: &cbor)  // ES256
    CBOR.appendInt(-1, to: &cbor)  // crv
    CBOR.appendInt(1, to: &cbor)  // P-256
    CBOR.appendInt(-2, to: &cbor)  // x
    CBOR.appendByteString(x, to: &cbor)
    CBOR.appendInt(-3, to: &cbor)  // y
    CBOR.appendByteString(y, to: &cbor)
    return cbor
  }

  /// Builds a "none"-format attestation object (§6.5.4 / §8.7): the CBOR map
  /// `{"fmt": "none", "attStmt": {}, "authData": authenticatorData}`.
  ///
  /// No signature over anything here — the "none" format exists precisely so an authenticator
  /// that has no attestation key (this one doesn't; it's software-only, sealed in the user's own
  /// vault) can say so honestly rather than fabricate one.
  static func attestationObject(authenticatorData: Data) -> Data {
    var cbor = Data()
    CBOR.appendMapHeader(count: 3, to: &cbor)
    CBOR.appendTextString("fmt", to: &cbor)
    CBOR.appendTextString("none", to: &cbor)
    CBOR.appendTextString("attStmt", to: &cbor)
    CBOR.appendMapHeader(count: 0, to: &cbor)
    CBOR.appendTextString("authData", to: &cbor)
    CBOR.appendByteString(authenticatorData, to: &cbor)
    return cbor
  }

  /// Signs an assertion (§6.3.3: "the assertion signature is produced over the concatenation of
  /// `authenticatorData` and `hash`", in that order, where `hash` is the relying party's
  /// `clientDataHash`), returning the DER-encoded ECDSA signature
  /// `AuthenticatorAssertionResponse.signature` carries on the wire.
  static func sign(
    authenticatorData: Data,
    clientDataHash: Data,
    privateKey: P256.Signing.PrivateKey
  ) throws -> Data {
    let signature = try privateKey.signature(for: authenticatorData + clientDataHash)
    return signature.derRepresentation
  }

  /// Verifies a signature produced by ``sign(authenticatorData:clientDataHash:privateKey:)``
  /// against the corresponding public key — used by ``PasskeyAuthenticatorTests``'s round trip,
  /// mirroring how a real relying party (e.g. webauthn.io) validates
  /// `AuthenticatorAssertionResponse.signature` server-side.
  static func verify(
    signature: Data,
    authenticatorData: Data,
    clientDataHash: Data,
    publicKey: P256.Signing.PublicKey
  ) -> Bool {
    guard let ecdsaSignature = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
    return publicKey.isValidSignature(ecdsaSignature, for: authenticatorData + clientDataHash)
  }
}
