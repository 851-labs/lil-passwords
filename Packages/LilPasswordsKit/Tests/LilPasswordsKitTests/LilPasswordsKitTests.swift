import Testing

@testable import LilPasswordsKit

@Test func productNames() {
  #expect(LilPasswordsKit.productName == "Lil Passwords")
  #expect(LilPasswordsKit.cliName == "lilpw")
}
