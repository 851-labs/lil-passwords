import Foundation
import LilPasswordsKit

#if DEBUG
  /// Realistic-looking placeholder items for previews, tophat, and manual testing — never built
  /// into a Release binary, and only seeded into a Debug build when explicitly asked for (see
  /// `InMemoryVaultViewModel.makeForCurrentLaunch()`).
  enum SampleData {
    static let items: [PasswordItem] = {
      let calendar = Calendar.current
      func daysAgo(_ days: Int) -> Date {
        calendar.date(byAdding: .day, value: -days, to: Date()) ?? Date()
      }

      return [
        PasswordItem(
          // Every sample item below gets a fixed, hardcoded id rather than the default
          // `UUID.v7()` (which stamps in the current time and would otherwise mint a fresh
          // random id on every single launch). Without this, the same-titled sample item gets a
          // different id — and so, via `ItemIconFactory`, a different header icon color — each
          // time the app is relaunched, which made two tophat screenshots of "the same item"
          // (e.g. one in read mode, one in edit mode, captured across separate launches) look
          // like a genuine color-consistency bug even though a single continuous session was
          // always consistent.
          id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
          title: "GitHub",
          usernames: ["octocat", "octocat@example.com"],
          password: "correct-horse-battery-staple",
          websites: [URL(string: "https://github.com")!, URL(string: "https://github.com/login")!],
          notes: "Personal account. Recovery codes are in the safe.",
          totpURI: "otpauth://totp/GitHub:octocat?secret=JBSWY3DPEHPK3PXP&issuer=GitHub",
          createdAt: daysAgo(400),
          modifiedAt: daysAgo(2)
        ),
        PasswordItem(
          id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
          title: "Amazon",
          usernames: ["jane.appleseed@example.com"],
          password: "Tr33House!42Sunset",
          websites: [URL(string: "https://www.amazon.com")!],
          notes: "",
          createdAt: daysAgo(730),
          modifiedAt: daysAgo(120)
        ),
        PasswordItem(
          id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
          title: "Netflix",
          usernames: ["jane.appleseed@example.com"],
          password: "popcorn-and-chill-99",
          websites: [URL(string: "https://www.netflix.com")!],
          notes: "Shared with the family plan.",
          totpURI: "otpauth://totp/Netflix:jane.appleseed@example.com?secret=KRSXG5CTMVRXEZLU&issuer=Netflix",
          createdAt: daysAgo(500),
          modifiedAt: daysAgo(30)
        ),
        PasswordItem(
          id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
          title: "Chase Bank",
          usernames: ["janeappleseed"],
          password: "V3ryS3cur3-Bank!ng2026",
          websites: [URL(string: "https://www.chase.com")!, URL(string: "https://secure.chase.com")!],
          notes: "Security questions answered with the usual fake answers, not real ones.",
          totpURI: "otpauth://totp/Chase:janeappleseed?secret=MFRGGZDFMZTWQ2LK&issuer=Chase",
          createdAt: daysAgo(900),
          modifiedAt: daysAgo(1)
        ),
        PasswordItem(
          id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
          title: "Figma",
          usernames: ["jane@studio.example"],
          password: "correct-horse-battery-staple",
          websites: [URL(string: "https://www.figma.com")!],
          notes: "",
          createdAt: daysAgo(200),
          modifiedAt: daysAgo(200)
        ),
        PasswordItem(
          id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
          title: "Local Coffee Shop Wi-Fi",
          usernames: [],
          password: "espresso-yourself",
          websites: [],
          notes: "Password changes every few months — ask the barista.",
          createdAt: daysAgo(60),
          modifiedAt: daysAgo(60)
        ),
        PasswordItem(
          id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!,
          title: "Old Forum Account",
          usernames: ["jappleseed", "jappleseed_backup"],
          password: "hunter2",
          websites: [URL(string: "https://forum.example.com")!],
          notes: "Barely used anymore.",
          createdAt: daysAgo(1800),
          modifiedAt: daysAgo(1500),
          securityWarningHidden: false
        ),
      ]
    }()
  }

  extension VaultStoreViewModel {
    /// Seeds sample data when this process was launched with `-SeedSampleData YES`, so previews,
    /// tophat, and manual testing all get believable data without needing a real vault. Never
    /// available outside Debug builds, and does nothing unless explicitly requested — a plain
    /// debug launch still starts from an empty vault.
    static func makeForCurrentLaunch() -> VaultStoreViewModel {
      guard UserDefaults.standard.string(forKey: "SeedSampleData") == "YES" else {
        return VaultStoreViewModel()
      }
      return VaultStoreViewModel(seedItems: SampleData.items)
    }
  }
#endif
