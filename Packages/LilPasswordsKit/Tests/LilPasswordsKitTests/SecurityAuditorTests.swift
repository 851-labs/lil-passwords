import Testing

@testable import LilPasswordsKit

/// A minimal, seeded xorshift generator so the "Apple-style password"
/// fixtures below are reproducible across runs without pulling in the real
/// `PasswordGenerator` (851-2406), which lives on a different branch and
/// isn't part of this package yet. `SecurityAuditor` only needs something
/// in the documented shape, not the real generator.
private struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed == 0 ? 0xdead_beef : seed
  }

  mutating func next() -> UInt64 {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return state
  }
}

/// Builds a password in the shape of Apple's "Strong Password" suggestion:
/// three six-letter lowercase groups joined by hyphens, with exactly one
/// letter uppercased and one letter replaced by a digit, e.g.
/// `"abcdef-ghijk2-lmNopq"`.
private func appleStyleStrongPassword(seed: UInt64) -> String {
  var rng = SeededGenerator(seed: seed)
  let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
  let digits = Array("0123456789")

  var letters = (0..<18).map { _ in lowercase.randomElement(using: &rng)! }
  let uppercaseIndex = Int.random(in: 0..<18, using: &rng)
  var digitIndex = Int.random(in: 0..<18, using: &rng)
  while digitIndex == uppercaseIndex {
    digitIndex = Int.random(in: 0..<18, using: &rng)
  }
  letters[uppercaseIndex] = Character(letters[uppercaseIndex].uppercased())
  letters[digitIndex] = digits.randomElement(using: &rng)!

  return stride(from: 0, to: 18, by: 6)
    .map { start in String(letters[start..<start + 6]) }
    .joined(separator: "-")
}

/// Whether `issues` contains a `.weak` finding, regardless of reason.
private func containsWeak(_ issues: Set<SecurityIssue>?) -> Bool {
  issues?.contains {
    if case .weak = $0 { return true }; return false
  } ?? false
}

/// The `WeakPasswordReasons` payload of `issues`' `.weak` finding, if any.
private func weakReasons(_ issues: Set<SecurityIssue>?) -> WeakPasswordReasons? {
  guard let issues else { return nil }
  for issue in issues {
    if case .weak(let reasons) = issue { return reasons }
  }
  return nil
}

@Suite struct SecurityAuditorTests {

  // MARK: - Common password list

  @Test func flagsExactCommonPasswords() {
    let auditor = SecurityAuditor()
    let issues = auditor.audit([AuditInput(id: "a", password: "password")])
    #expect(weakReasons(issues["a"])?.contains(.commonPassword) == true)
  }

  @Test func commonPasswordMatchIsCaseInsensitive() {
    let auditor = SecurityAuditor()
    let issues = auditor.audit([AuditInput(id: "a", password: "PaSsWoRd")])
    #expect(weakReasons(issues["a"])?.contains(.commonPassword) == true)
  }

  @Test func commonPasswordMatchIgnoresATrailingDigitSuffix() {
    let auditor = SecurityAuditor()
    let issues = auditor.audit([AuditInput(id: "a", password: "password123")])
    #expect(weakReasons(issues["a"])?.contains(.commonPassword) == true)
  }

  @Test func commonPasswordMatchCatchesSimpleLeetspeakSubstitution() {
    let auditor = SecurityAuditor()
    let issues = auditor.audit([AuditInput(id: "a", password: "P@ssw0rd")])
    #expect(weakReasons(issues["a"])?.contains(.commonPassword) == true)
  }

  // MARK: - Sequences

  @Test func flagsAscendingAndDescendingSequences() {
    let auditor = SecurityAuditor()
    let issues = auditor.audit([
      AuditInput(id: "ascending", password: "12345678"),
      AuditInput(id: "descending", password: "hgfedcba"),
    ])
    #expect(weakReasons(issues["ascending"])?.contains(.sequence) == true)
    #expect(weakReasons(issues["descending"])?.contains(.sequence) == true)
  }

  @Test func doesNotFlagAShortRunBelowTheSequenceThreshold() {
    let auditor = SecurityAuditor()
    // "abc" is only 3 characters — below the 4-character minimum — so it
    // shouldn't trip the sequence check (it may still be weak for other
    // reasons, like low entropy).
    let issues = auditor.audit([AuditInput(id: "a", password: "abc")])
    #expect(weakReasons(issues["a"])?.contains(.sequence) != true)
  }

  // MARK: - Repeats

  @Test func flagsARepeatedSingleCharacter() {
    let auditor = SecurityAuditor()
    let issues = auditor.audit([AuditInput(id: "a", password: "aaaaaa")])
    #expect(weakReasons(issues["a"])?.contains(.repeatedCharacters) == true)
  }

  @Test func flagsARepeatedTwoCharacterBlock() {
    let auditor = SecurityAuditor()
    let issues = auditor.audit([AuditInput(id: "a", password: "ababab")])
    #expect(weakReasons(issues["a"])?.contains(.repeatedCharacters) == true)
  }

  @Test func flagsARepeatedThreeCharacterBlock() {
    let auditor = SecurityAuditor()
    let issues = auditor.audit([AuditInput(id: "a", password: "abcabcabc")])
    #expect(weakReasons(issues["a"])?.contains(.repeatedCharacters) == true)
  }

  // MARK: - Keyboard patterns

  @Test func flagsKeyboardRowWalks() {
    let auditor = SecurityAuditor()
    let issues = auditor.audit([
      AuditInput(id: "top", password: "qwertyuiop"),
      AuditInput(id: "home", password: "asdfgh"),
      AuditInput(id: "bottom", password: "zxcvbn"),
      AuditInput(id: "reversed", password: "nbvcxz"),
    ])
    for id in ["top", "home", "bottom", "reversed"] {
      #expect(weakReasons(issues[id])?.contains(.keyboardPattern) == true, "id: \(id)")
    }
  }

  // MARK: - Entropy

  @Test func flagsLowEntropyPasswordsWithNoOtherPattern() {
    let auditor = SecurityAuditor()
    // Six lowercase letters, no sequence/repeat/keyboard-walk/common-list
    // match, but too small a search space to be anything but weak.
    let issues = auditor.audit([AuditInput(id: "a", password: "fjqzmv")])
    let reasons = weakReasons(issues["a"])
    #expect(reasons?.contains(.lowEntropy) == true)
    #expect(reasons?.contains(.sequence) != true)
    #expect(reasons?.contains(.repeatedCharacters) != true)
    #expect(reasons?.contains(.keyboardPattern) != true)
    #expect(reasons?.contains(.commonPassword) != true)
  }

  @Test func doesNotFlagALongMixedCategoryPassword() {
    let auditor = SecurityAuditor()
    let issues = auditor.audit([AuditInput(id: "a", password: "K7\u{24}mQ9!vLp2&hX4s")])
    #expect(containsWeak(issues["a"]) == false)
  }

  @Test func emptyPasswordIsFlaggedWeakForLowEntropyOnly() {
    let auditor = SecurityAuditor()
    let issues = auditor.audit([AuditInput(id: "a", password: "")])
    #expect(weakReasons(issues["a"]) == .lowEntropy)
  }

  // MARK: - Apple-generated strong passwords are never weak

  @Test func appleStyleStrongPasswordsAreNeverFlaggedWeak() {
    let auditor = SecurityAuditor()
    for seed in UInt64(1)...200 {
      let password = appleStyleStrongPassword(seed: seed)
      let issues = auditor.audit([AuditInput(id: "only", password: password)])
      #expect(containsWeak(issues["only"]) == false, "flagged weak: \(password)")
    }
  }

  // MARK: - Reuse detection

  @Test func flagsIdenticalPasswordsAsReused() {
    let auditor = SecurityAuditor()
    let issues = auditor.audit([
      AuditInput(id: "a", password: "correct-horse-battery-staple-9K"),
      AuditInput(id: "b", password: "correct-horse-battery-staple-9K"),
      AuditInput(id: "c", password: "a-totally-different-passphrase-4Q"),
    ])
    #expect(issues["a"]?.contains(.reused) == true)
    #expect(issues["b"]?.contains(.reused) == true)
    #expect(issues["c"]?.contains(.reused) != true)
  }

  @Test func doesNotFlagAUniquePasswordAsReused() {
    let auditor = SecurityAuditor()
    let issues = auditor.audit([AuditInput(id: "a", password: "a-totally-unique-passphrase-7Z")])
    #expect(issues["a"]?.contains(.reused) != true)
  }

  @Test func reuseGroupsOfThreeOrMoreAllFlagEachOther() {
    let auditor = SecurityAuditor()
    let issues = auditor.audit([
      AuditInput(id: "a", password: "shared-secret-42Q"),
      AuditInput(id: "b", password: "shared-secret-42Q"),
      AuditInput(id: "c", password: "shared-secret-42Q"),
    ])
    for id in ["a", "b", "c"] {
      #expect(issues[id]?.contains(.reused) == true)
    }
  }

  // MARK: - Hidden warnings

  @Test func hiddenWarningSuppressesIssuesForThatEntryOnly() {
    let auditor = SecurityAuditor()
    let issues = auditor.audit([
      AuditInput(id: "hidden", password: "password", hiddenWarning: true),
      AuditInput(id: "visible", password: "password", hiddenWarning: false),
    ])
    #expect(issues["hidden"] == nil)
    #expect(weakReasons(issues["visible"])?.contains(.commonPassword) == true)
    #expect(issues["visible"]?.contains(.reused) == true)
  }

  @Test func hiddenEntryStillCountsTowardReuseGroupingForOthers() {
    let auditor = SecurityAuditor()
    // Even though "hidden" won't itself report any issues, its shared
    // password should still cause "visible" to be flagged as reused.
    let issues = auditor.audit([
      AuditInput(id: "hidden", password: "shared-9Z-passphrase", hiddenWarning: true),
      AuditInput(id: "visible", password: "shared-9Z-passphrase", hiddenWarning: false),
    ])
    #expect(issues["hidden"] == nil)
    #expect(issues["visible"]?.contains(.reused) == true)
  }

  // MARK: - Output shape

  @Test func entriesWithNoIssuesAreAbsentFromTheResult() {
    let auditor = SecurityAuditor()
    let issues = auditor.audit([AuditInput(id: "a", password: "K7\u{24}mQ9!vLp2&hX4s")])
    #expect(issues["a"] == nil)
    #expect(issues.isEmpty)
  }

  @Test func emptyInputProducesEmptyOutput() {
    let auditor = SecurityAuditor()
    let issues: [String: Set<SecurityIssue>] = auditor.audit([AuditInput<String>]())
    #expect(issues.isEmpty)
  }

  @Test func idTypeIsGeneric() {
    let auditor = SecurityAuditor()
    let issues = auditor.audit([
      AuditInput(id: 1, password: "password"),
      AuditInput(id: 2, password: "a-totally-unique-passphrase-7Z"),
    ])
    #expect(weakReasons(issues[1])?.contains(.commonPassword) == true)
    #expect(issues[2] == nil)
  }
}
