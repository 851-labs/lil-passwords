import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct PasswordItemChangePasswordURLTests {
  @Test func usesTheFirstWebsitesHost() {
    let item = PasswordItem(title: "GitHub", websites: [URL(string: "https://github.com/settings")!])
    #expect(item.changePasswordURL == URL(string: "https://github.com/.well-known/change-password"))
  }

  @Test func ignoresWebsitesAfterTheFirst() {
    let item = PasswordItem(
      title: "Example",
      websites: [
        URL(string: "https://example.com")!,
        URL(string: "https://second.example.com")!,
      ]
    )
    #expect(item.changePasswordURL == URL(string: "https://example.com/.well-known/change-password"))
  }

  @Test func isNilWithNoWebsites() {
    let item = PasswordItem(title: "No Website")
    #expect(item.changePasswordURL == nil)
  }
}
