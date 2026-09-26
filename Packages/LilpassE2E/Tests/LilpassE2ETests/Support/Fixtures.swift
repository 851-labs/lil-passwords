import Foundation
import LilPasswordsKit

/// Builds a `PasswordItem` with whole-second timestamps, matching `LilpassCoreTests`/
/// `LilpassMCPTests`'s own `makeTestItem` helper: `AgentWireCoding`'s `.iso8601` date strategy drops
/// sub-second precision, and these items also cross an actual base64-in-an-environment-variable
/// round trip (`E2EHelperProcess` → `LilpassE2EHelper`) before `LilpassE2EHelper` ever seeds them, so
/// keeping timestamps second-granular avoids any risk of a test comparing against a value that
/// silently lost precision somewhere along the way.
func makeE2ETestItem(
  title: String = "GitHub",
  usernames: [String] = ["octocat"],
  password: String = "hunter2",
  websites: [URL] = [],
  notes: String = "",
  totpURI: String? = nil,
  group: String? = nil
) -> PasswordItem {
  PasswordItem(
    title: title,
    usernames: usernames,
    password: password,
    websites: websites,
    notes: notes,
    totpURI: totpURI,
    group: group,
    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
    modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
  )
}
