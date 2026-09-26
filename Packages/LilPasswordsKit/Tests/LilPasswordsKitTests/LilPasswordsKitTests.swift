import Testing

@testable import LilPasswordsKit

@Test func productNames() {
  #expect(LilPasswordsKit.productName == "lil passwords")
  #expect(LilPasswordsKit.cliName == "lilpw")
}
