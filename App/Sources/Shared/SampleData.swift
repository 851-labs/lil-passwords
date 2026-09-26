import Foundation
import LilPasswordsKit

/// Realistic-looking `PasswordItem`s for previews and DEBUG tophat builds, used in place of real
/// vault data while `VaultStore` (851-2404) and the XPC helper (851-2427) are still in progress.
///
/// Only ever compiled into DEBUG builds — there is no way to seed sample data into a Release
/// build, intentionally, since this is fake data standing in for a user's real passwords.
public enum SampleData {
  /// Whether the app was launched with `-SeedSampleData YES`. Always `false` outside DEBUG.
  public static var isEnabled: Bool {
    #if DEBUG
      return UserDefaults.standard.bool(forKey: "SeedSampleData")
    #else
      return false
    #endif
  }

  #if DEBUG
    /// Builds a fresh set of sample items, spanning many initial letters (to exercise the item
    /// list's alphabetical section headers), a handful of two-factor codes, and a couple of
    /// soft-deleted items (to exercise the Deleted sidebar category).
    public static func makeItems(now: Date = Date()) -> [PasswordItem] {
      func days(_ count: Double) -> Date { now.addingTimeInterval(-count * 86_400) }

      func totpURI(issuer: String, accountName: String, secret: String) -> String {
        guard let secretData = Base32.decode(secret), let totp = try? TOTP(secret: secretData) else {
          return ""
        }
        return OTPAuthURI(issuer: issuer, accountName: accountName, totp: totp).url.absoluteString
      }

      return [
        PasswordItem(
          title: "Amazon",
          usernames: ["jordan.reyes@icloud.com"],
          password: "Am4z0n!Basket-92",
          websites: [URL(string: "https://www.amazon.com")!],
          group: "Shopping",
          createdAt: days(410),
          modifiedAt: days(12)
        ),
        PasswordItem(
          title: "Apple",
          usernames: ["jordan.reyes@icloud.com"],
          password: "Cloudy-Kite-4471",
          websites: [URL(string: "https://appleid.apple.com")!],
          totpURI: totpURI(issuer: "Apple", accountName: "jordan.reyes@icloud.com", secret: "JBSWY3DPEHPK3PXP"),
          group: "Personal",
          createdAt: days(700),
          modifiedAt: days(2),
          lastUsedAt: days(1)
        ),
        PasswordItem(
          title: "Bank of America",
          usernames: ["jreyes1990"],
          password: "Vault-Bramble-88",
          websites: [URL(string: "https://www.bankofamerica.com")!],
          notes: "Checking + savings",
          group: "Finance",
          createdAt: days(600),
          modifiedAt: days(180)
        ),
        PasswordItem(
          title: "Chime",
          usernames: ["jordan.reyes"],
          password: "Wander-Folio-15",
          websites: [URL(string: "https://www.chime.com")!],
          group: "Finance",
          createdAt: days(300),
          modifiedAt: days(300)
        ),
        PasswordItem(
          title: "Dropbox",
          usernames: ["jordan.reyes@icloud.com"],
          password: "Sunlit-Paper-63",
          websites: [URL(string: "https://www.dropbox.com")!],
          totpURI: totpURI(issuer: "Dropbox", accountName: "jordan.reyes@icloud.com", secret: "NB2W45DFOIZA"),
          group: "Work",
          createdAt: days(250),
          modifiedAt: days(90)
        ),
        PasswordItem(
          title: "Etsy",
          usernames: ["jreyes.crafts"],
          password: "Thimble-Yarn-27",
          websites: [URL(string: "https://www.etsy.com")!],
          group: "Shopping",
          createdAt: days(140),
          modifiedAt: days(140)
        ),
        PasswordItem(
          title: "Figma",
          usernames: ["jordan@studio.example"],
          password: "Vector-Canvas-71",
          websites: [URL(string: "https://www.figma.com")!],
          group: "Work",
          createdAt: days(220),
          modifiedAt: days(45)
        ),
        PasswordItem(
          title: "GitHub",
          usernames: ["jreyes-dev"],
          password: "Octo-Commit-509",
          websites: [URL(string: "https://github.com")!],
          totpURI: totpURI(issuer: "GitHub", accountName: "jreyes-dev", secret: "KRSXG5CTMVRXEZLU"),
          group: "Work",
          createdAt: days(500),
          modifiedAt: days(3),
          lastUsedAt: days(3)
        ),
        PasswordItem(
          title: "Hulu",
          usernames: ["jordan.reyes@icloud.com"],
          password: "Popcorn-Marathon-8",
          websites: [URL(string: "https://www.hulu.com")!],
          group: "Entertainment",
          createdAt: days(365),
          modifiedAt: days(365)
        ),
        PasswordItem(
          title: "IKEA Family",
          usernames: ["jordan.reyes@icloud.com"],
          password: "Flatpack-Allen-14",
          websites: [URL(string: "https://www.ikea.com")!],
          group: "Shopping",
          createdAt: days(90),
          modifiedAt: days(90)
        ),
        PasswordItem(
          title: "JetBlue",
          usernames: ["jreyes1990"],
          password: "TrueBlue-Runway-3",
          websites: [URL(string: "https://www.jetblue.com")!],
          group: "Travel",
          createdAt: days(75),
          modifiedAt: days(20)
        ),
        PasswordItem(
          title: "Kroger",
          usernames: ["jordan.reyes@icloud.com"],
          password: "Basket-Coupon-42",
          websites: [URL(string: "https://www.kroger.com")!],
          group: "Shopping",
          createdAt: days(60),
          modifiedAt: days(60)
        ),
        PasswordItem(
          title: "LinkedIn",
          usernames: ["jordan.reyes@icloud.com"],
          password: "Network-Ladder-77",
          websites: [URL(string: "https://www.linkedin.com")!],
          group: "Work",
          createdAt: days(480),
          modifiedAt: days(15)
        ),
        PasswordItem(
          title: "Mint Mobile",
          usernames: ["jreyes1990"],
          password: "Cricket-Signal-19",
          websites: [URL(string: "https://www.mintmobile.com")!],
          group: "Utilities",
          createdAt: days(200),
          modifiedAt: days(200)
        ),
        PasswordItem(
          title: "Notion",
          usernames: ["jordan@studio.example"],
          password: "Blocky-Outline-33",
          websites: [URL(string: "https://www.notion.so")!],
          totpURI: totpURI(issuer: "Notion", accountName: "jordan@studio.example", secret: "ONSWG4TFOQ"),
          group: "Work",
          createdAt: days(160),
          modifiedAt: days(6)
        ),
        PasswordItem(
          title: "Peloton",
          usernames: ["jordan.reyes@icloud.com"],
          password: "Cadence-Climb-56",
          websites: [URL(string: "https://www.onepeloton.com")!],
          group: "Health",
          createdAt: days(130),
          modifiedAt: days(130)
        ),
        PasswordItem(
          title: "Quora",
          usernames: ["jreyes.reads"],
          password: "Curious-Answer-81",
          websites: [URL(string: "https://www.quora.com")!],
          group: "Personal",
          createdAt: days(320),
          modifiedAt: days(320),
          deletedAt: days(4)
        ),
        PasswordItem(
          title: "Reddit",
          usernames: ["u_jreyes"],
          password: "Upvote-Karma-24",
          websites: [URL(string: "https://www.reddit.com")!],
          group: "Personal",
          createdAt: days(510),
          modifiedAt: days(510),
          deletedAt: days(1)
        ),
        PasswordItem(
          title: "Spotify",
          usernames: ["jordan.reyes@icloud.com"],
          password: "Playlist-Encore-67",
          websites: [URL(string: "https://www.spotify.com")!],
          group: "Entertainment",
          createdAt: days(650),
          modifiedAt: days(30),
          lastUsedAt: days(2)
        ),
        PasswordItem(
          title: "Trello",
          usernames: ["jordan@studio.example"],
          password: "Kanban-Sprint-98",
          websites: [URL(string: "https://trello.com")!],
          group: "Work",
          createdAt: days(190),
          modifiedAt: days(190)
        ),
        PasswordItem(
          title: "Uber",
          usernames: ["jordan.reyes@icloud.com"],
          password: "Rideshare-Meter-11",
          websites: [URL(string: "https://www.uber.com")!],
          group: "Travel",
          createdAt: days(100),
          modifiedAt: days(5)
        ),
        PasswordItem(
          title: "Venmo",
          usernames: ["jreyes1990"],
          password: "Splitcheck-Coin-29",
          websites: [URL(string: "https://venmo.com")!],
          totpURI: totpURI(issuer: "Venmo", accountName: "jreyes1990", secret: "MFRGGZDFMZTWQ2LK"),
          group: "Finance",
          createdAt: days(340),
          modifiedAt: days(9)
        ),
        PasswordItem(
          title: "Wayfair",
          usernames: ["jordan.reyes@icloud.com"],
          password: "Furnish-Crate-40",
          websites: [URL(string: "https://www.wayfair.com")!],
          group: "Shopping",
          createdAt: days(50),
          modifiedAt: days(50)
        ),
        // The remaining two items exist to exercise the Security sidebar category (851-2419):
        // Peacock reuses Hulu's password above, and Yelp's password is on the bundled
        // common-password list, so together they populate both the "Reused" and "Weak" groups.
        PasswordItem(
          title: "Peacock",
          usernames: ["jordan.reyes@icloud.com"],
          password: "Popcorn-Marathon-8",
          websites: [URL(string: "https://www.peacocktv.com")!],
          group: "Entertainment",
          createdAt: days(70),
          modifiedAt: days(70)
        ),
        PasswordItem(
          title: "Yelp",
          usernames: ["jordan.reyes@icloud.com"],
          password: "letmein1",
          websites: [URL(string: "https://www.yelp.com")!],
          group: "Personal",
          createdAt: days(40),
          modifiedAt: days(40)
        ),
      ]
    }
  #endif
}
