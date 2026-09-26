import CryptoKit
import Foundation
import Testing

@testable import LilPasswordsKit

/// 851-2442's explicitly required tests: `authenticatorData` encoding (rpIdHash, flags, signCount,
/// attestedCredentialData with a COSE EC2 key) and an assertion signature verification round trip.
@Suite struct PasskeyAuthenticatorTests {
  // MARK: - authenticatorData encoding

  @Test func authenticatorDataEncodesRpIdHashFlagsAndSignCountWithNoAttestedCredentialData() {
    let data = PasskeyAuthenticator.authenticatorData(
      relyingPartyIdentifier: "webauthn.io",
      signCount: 0x0000_002A
    )

    // rpIdHash: the first 32 bytes are SHA-256 of the UTF-8 relying party identifier (§6.1).
    let expectedRpIdHash = Data(SHA256.hash(data: Data("webauthn.io".utf8)))
    #expect(data.count == 37)
    #expect(data.prefix(32) == expectedRpIdHash)

    // flags: UP (0x01) and UV (0x04) are always set by lil passwords; AT (0x40) is not, since no
    // attestedCredentialData was supplied (an assertion, not a registration) — see §6.1 Table 4.
    let flags = data[data.startIndex + 32]
    #expect(flags == 0x05)

    // signCount: 4 bytes, big-endian, immediately after the flags byte.
    let signCountBytes = data.subdata(in: (data.startIndex + 33)..<(data.startIndex + 37))
    #expect(signCountBytes == Data([0x00, 0x00, 0x00, 0x2A]))
  }

  @Test func authenticatorDataSetsTheAttestedCredentialDataFlagAndAppendsItWhenSupplied() {
    let credentialId = Data(repeating: 0xCC, count: 16)
    let privateKey = P256.Signing.PrivateKey()
    let attestedCredentialData = PasskeyAuthenticator.attestedCredentialData(
      credentialId: credentialId,
      publicKey: privateKey.publicKey
    )

    let data = PasskeyAuthenticator.authenticatorData(
      relyingPartyIdentifier: "webauthn.io",
      signCount: 0,
      attestedCredentialData: attestedCredentialData
    )

    let flags = data[data.startIndex + 32]
    // UP | UV | AT = 0x01 | 0x04 | 0x40 = 0x45.
    #expect(flags == 0x45)
    #expect(data.count == 37 + attestedCredentialData.count)
    #expect(data.suffix(attestedCredentialData.count) == attestedCredentialData)
  }

  @Test func authenticatorDataClearsUserPresentAndUserVerifiedWhenRequested() {
    let data = PasskeyAuthenticator.authenticatorData(
      relyingPartyIdentifier: "webauthn.io",
      userPresent: false,
      userVerified: false,
      signCount: 0
    )
    #expect(data[data.startIndex + 32] == 0x00)
  }

  // MARK: - attestedCredentialData / COSE_Key encoding

  @Test func attestedCredentialDataEncodesAaguidCredentialIdLengthAndCredentialIdBeforeTheCoseKey() {
    let credentialId = Data([0x01, 0x02, 0x03, 0x04, 0x05])
    let privateKey = P256.Signing.PrivateKey()
    let data = PasskeyAuthenticator.attestedCredentialData(credentialId: credentialId, publicKey: privateKey.publicKey)

    // aaguid: 16 zero bytes (§6.5.2) — lil passwords makes no attestation claim about a specific
    // authenticator model.
    #expect(data.prefix(16) == PasskeyAuthenticator.aaguid)
    #expect(PasskeyAuthenticator.aaguid == Data(repeating: 0, count: 16))

    // credentialIdLength: 2 bytes, big-endian.
    let lengthBytes = data.subdata(in: (data.startIndex + 16)..<(data.startIndex + 18))
    #expect(lengthBytes == Data([0x00, 0x05]))

    // credentialId itself, verbatim.
    let embeddedCredentialId = data.subdata(in: (data.startIndex + 18)..<(data.startIndex + 23))
    #expect(embeddedCredentialId == credentialId)

    // The remainder is the COSE_Key — verified in detail below via `coseKey(for:)` directly.
    let coseKey = data.suffix(from: data.startIndex + 23)
    #expect(Data(coseKey) == PasskeyAuthenticator.coseKey(for: privateKey.publicKey))
  }

  @Test func coseKeyEncodesA5EntryEC2MapWithES256AndP256CoordinateBytes() {
    let privateKey = P256.Signing.PrivateKey()
    let point = privateKey.publicKey.x963Representation
    let x = point.subdata(in: 1..<33)
    let y = point.subdata(in: 33..<65)

    let cbor = PasskeyAuthenticator.coseKey(for: privateKey.publicKey)

    // Canonical CBOR, byte for byte: a 5-entry map (0xA5), then kty=2 (EC2), alg=-7 (ES256),
    // crv=1 (P-256), x, y — see RFC 9053 §7.1.1.
    var expected = Data([
      0xA5,
      0x01, 0x02,  // kty: EC2
      0x03, 0x26,  // alg: ES256 (-7)
      0x20, 0x01,  // crv: P-256 (1)
      0x21, 0x58, 0x20,  // x: byte string, 32 bytes
    ])
    expected.append(x)
    expected.append(contentsOf: [0x22, 0x58, 0x20])  // y: byte string, 32 bytes
    expected.append(y)

    #expect(cbor == expected)
  }

  // MARK: - "none" attestation object

  @Test func attestationObjectWrapsAuthenticatorDataInANoneFormatCBORMap() {
    let authenticatorData = Data([0x01, 0x02, 0x03])
    let attestationObject = PasskeyAuthenticator.attestationObject(authenticatorData: authenticatorData)

    var expected = Data([
      0xA3,  // map, 3 pairs
      0x63, 0x66, 0x6D, 0x74,  // "fmt" (3 chars)
      0x64, 0x6E, 0x6F, 0x6E, 0x65,  // "none" (4 chars)
      0x67, 0x61, 0x74, 0x74, 0x53, 0x74, 0x6D, 0x74,  // "attStmt" (7 chars)
      0xA0,  // {} — empty map: no attestation signature at all
      0x68, 0x61, 0x75, 0x74, 0x68, 0x44, 0x61, 0x74, 0x61,  // "authData" (8 chars)
      0x43,  // byte string, 3 bytes
    ])
    expected.append(authenticatorData)

    #expect(attestationObject == expected)
  }

  // MARK: - Signature verification round trip

  @Test func signThenVerifyRoundTripsForTheAssertionSignatureBase() throws {
    let privateKey = P256.Signing.PrivateKey()
    let authenticatorData = PasskeyAuthenticator.authenticatorData(relyingPartyIdentifier: "webauthn.io", signCount: 1)
    let clientDataHash = Data(SHA256.hash(data: Data("some clientDataJSON".utf8)))

    let signature = try PasskeyAuthenticator.sign(
      authenticatorData: authenticatorData,
      clientDataHash: clientDataHash,
      privateKey: privateKey
    )

    #expect(
      PasskeyAuthenticator.verify(
        signature: signature,
        authenticatorData: authenticatorData,
        clientDataHash: clientDataHash,
        publicKey: privateKey.publicKey
      )
    )
  }

  @Test func verifyFailsWhenTheClientDataHashDoesNotMatchWhatWasSigned() throws {
    let privateKey = P256.Signing.PrivateKey()
    let authenticatorData = PasskeyAuthenticator.authenticatorData(relyingPartyIdentifier: "webauthn.io", signCount: 1)
    let clientDataHash = Data(SHA256.hash(data: Data("original".utf8)))
    let tamperedClientDataHash = Data(SHA256.hash(data: Data("tampered".utf8)))

    let signature = try PasskeyAuthenticator.sign(
      authenticatorData: authenticatorData,
      clientDataHash: clientDataHash,
      privateKey: privateKey
    )

    #expect(
      !PasskeyAuthenticator.verify(
        signature: signature,
        authenticatorData: authenticatorData,
        clientDataHash: tamperedClientDataHash,
        publicKey: privateKey.publicKey
      )
    )
  }

  @Test func verifyFailsForTheWrongPublicKey() throws {
    let privateKey = P256.Signing.PrivateKey()
    let otherPrivateKey = P256.Signing.PrivateKey()
    let authenticatorData = PasskeyAuthenticator.authenticatorData(relyingPartyIdentifier: "webauthn.io", signCount: 1)
    let clientDataHash = Data(SHA256.hash(data: Data("some clientDataJSON".utf8)))

    let signature = try PasskeyAuthenticator.sign(
      authenticatorData: authenticatorData,
      clientDataHash: clientDataHash,
      privateKey: privateKey
    )

    #expect(
      !PasskeyAuthenticator.verify(
        signature: signature,
        authenticatorData: authenticatorData,
        clientDataHash: clientDataHash,
        publicKey: otherPrivateKey.publicKey
      )
    )
  }

  @Test func verifyRejectsAMalformedSignature() {
    let privateKey = P256.Signing.PrivateKey()
    let authenticatorData = PasskeyAuthenticator.authenticatorData(relyingPartyIdentifier: "webauthn.io", signCount: 1)
    let clientDataHash = Data(SHA256.hash(data: Data("some clientDataJSON".utf8)))

    #expect(
      !PasskeyAuthenticator.verify(
        signature: Data([0xDE, 0xAD, 0xBE, 0xEF]),
        authenticatorData: authenticatorData,
        clientDataHash: clientDataHash,
        publicKey: privateKey.publicKey
      )
    )
  }
}
