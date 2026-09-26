import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct OTPAuthURITests {
  // Google Authenticator's canonical "Key Uri Format" example.
  static let googleExampleURI =
    "otpauth://totp/ACME%20Co:john.doe@email.com"
    + "?secret=HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ&issuer=ACME%20Co&algorithm=SHA1&digits=6&period=30"

  @Test func parsesGoogleAuthenticatorExample() throws {
    let url = try #require(URL(string: Self.googleExampleURI))
    let parsed = try OTPAuthURI(url: url)

    #expect(parsed.issuer == "ACME Co")
    #expect(parsed.accountName == "john.doe@email.com")
    #expect(parsed.totp.algorithm == .sha1)
    #expect(parsed.totp.digits == 6)
    #expect(parsed.totp.period == 30)
    #expect(parsed.totp.secret == Base32.decode("HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ"))
  }

  @Test func parsesLabelWithoutIssuer() throws {
    let url = try #require(URL(string: "otpauth://totp/john.doe@email.com?secret=JBSWY3DPEHPK3PXP"))
    let parsed = try OTPAuthURI(url: url)

    #expect(parsed.issuer == nil)
    #expect(parsed.accountName == "john.doe@email.com")
    #expect(parsed.totp.algorithm == .sha1)
    #expect(parsed.totp.digits == 6)
    #expect(parsed.totp.period == 30)
  }

  @Test func queryIssuerWinsOverLabelIssuer() throws {
    let url = try #require(URL(string: "otpauth://totp/Old%20Name:jane?secret=JBSWY3DPEHPK3PXP&issuer=New%20Name"))
    let parsed = try OTPAuthURI(url: url)
    #expect(parsed.issuer == "New Name")
  }

  @Test func fallsBackToLabelIssuerWhenQueryIssuerIsAbsent() throws {
    let url = try #require(URL(string: "otpauth://totp/Acme:jane?secret=JBSWY3DPEHPK3PXP"))
    let parsed = try OTPAuthURI(url: url)
    #expect(parsed.issuer == "Acme")
  }

  @Test func rejectsHOTP() {
    do {
      _ = try OTPAuthURI(url: URL(string: "otpauth://hotp/jane?secret=JBSWY3DPEHPK3PXP&counter=0")!)
      Issue.record("Expected OTPAuthURI.Error.unsupportedType")
    } catch let error as OTPAuthURI.Error {
      #expect(error == .unsupportedType("hotp"))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func rejectsMissingSecret() {
    do {
      _ = try OTPAuthURI(url: URL(string: "otpauth://totp/jane")!)
      Issue.record("Expected OTPAuthURI.Error.missingSecret")
    } catch let error as OTPAuthURI.Error {
      #expect(error == .missingSecret)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func rejectsInvalidBase32Secret() {
    do {
      _ = try OTPAuthURI(url: URL(string: "otpauth://totp/jane?secret=not-valid-base32!")!)
      Issue.record("Expected OTPAuthURI.Error.invalidSecret")
    } catch let error as OTPAuthURI.Error {
      #expect(error == .invalidSecret)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func rejectsWrongScheme() {
    do {
      _ = try OTPAuthURI(url: URL(string: "https://totp/jane?secret=JBSWY3DPEHPK3PXP")!)
      Issue.record("Expected OTPAuthURI.Error.invalidScheme")
    } catch let error as OTPAuthURI.Error {
      #expect(error == .invalidScheme("https"))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func roundTripsThroughSerialization() throws {
    let totp = try TOTP(secret: Data("12345678901234567890".utf8), algorithm: .sha256, digits: 8, period: 60)
    let original = OTPAuthURI(issuer: "Acme Corp", accountName: "alex@example.com", totp: totp)

    let reparsed = try OTPAuthURI(url: original.url)

    #expect(reparsed.issuer == original.issuer)
    #expect(reparsed.accountName == original.accountName)
    #expect(reparsed.totp == original.totp)
  }

  @Test func roundTripsWithoutIssuer() throws {
    let totp = try TOTP(secret: Data([1, 2, 3, 4, 5]))
    let original = OTPAuthURI(accountName: "alex@example.com", totp: totp)

    let reparsed = try OTPAuthURI(url: original.url)

    #expect(reparsed.issuer == nil)
    #expect(reparsed.accountName == original.accountName)
    #expect(reparsed.totp == original.totp)
  }
}
