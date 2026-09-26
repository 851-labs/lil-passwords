import CryptoKit
import Foundation

/// One vault entry's password, as seen by ``SecurityAuditor``.
///
/// This is a small, standalone type rather than the eventual vault item
/// model (which doesn't exist yet) — it carries only what the audit needs.
/// `id` is generic so any identifier type (e.g. a future item's `UUID`) can
/// be used without `SecurityAuditor` depending on that type.
public struct AuditInput<ID: Hashable & Sendable>: Sendable, Hashable {
  public var id: ID
  public var password: String

  /// Whether the item's owner has dismissed the security warning for this
  /// entry. Hidden entries are still considered when grouping reused
  /// passwords across the vault, but never contribute their own issues to
  /// ``SecurityAuditor/audit(_:)``'s output.
  public var hiddenWarning: Bool

  public init(id: ID, password: String, hiddenWarning: Bool = false) {
    self.id = id
    self.password = password
    self.hiddenWarning = hiddenWarning
  }
}

/// A specific reason ``SecurityIssue/weak(_:)`` was raised. A password can
/// trigger more than one at once (e.g. a common password that's also a
/// keyboard walk).
public struct WeakPasswordReasons: OptionSet, Sendable, Hashable {
  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  /// The password (or its digit-stripped/leetspeak-normalized core)
  /// exactly matches an entry in the bundled common-password list.
  public static let commonPassword = WeakPasswordReasons(rawValue: 1 << 0)

  /// The whole password is a monotonic run, e.g. `"12345678"` or
  /// `"hgfedcba"`.
  public static let sequence = WeakPasswordReasons(rawValue: 1 << 1)

  /// The whole password is a single repeated character or a short block
  /// repeated end to end, e.g. `"aaaaaa"` or `"abcabcabc"`.
  public static let repeatedCharacters = WeakPasswordReasons(rawValue: 1 << 2)

  /// The whole password is a run of physically adjacent keys, e.g.
  /// `"qwerty"` or `"zxcvbn"`.
  public static let keyboardPattern = WeakPasswordReasons(rawValue: 1 << 3)

  /// The password's estimated entropy, given the character categories it
  /// draws from, falls below a "reasonably guessable" threshold.
  public static let lowEntropy = WeakPasswordReasons(rawValue: 1 << 4)
}

/// A local security finding for a vault entry.
public enum SecurityIssue: Sendable, Hashable {
  /// The password scores as weak by ``SecurityAuditor``'s zxcvbn-style
  /// estimate, for the given ``WeakPasswordReasons``.
  case weak(WeakPasswordReasons)

  /// The password is identical to at least one other audited entry.
  case reused
}

/// Runs local, on-device security checks against vault passwords.
///
/// Two checks feed the Security sidebar:
/// - **Weak**: a lightweight, zxcvbn-style strength estimate — a small
///   built-in common-password list, sequence/repeat/keyboard-pattern
///   detection, and a character-pool entropy estimate.
/// - **Reused**: entries that share the exact same password.
///
/// Everything here runs entirely on-device: there is no network access and
/// no integration with breach-list services such as HIBP. That's
/// ``CompromisedPasswordChecker`` instead (851-2458) — a separate, opt-in,
/// async component, deliberately kept out of this pure/synchronous auditor.
public struct SecurityAuditor: Sendable {
  private static let lowEntropyThresholdBits: Double = 40
  private static let patternMinimumLength = 4
  private static let symbolPoolSize = 33

  private static let keyboardRows: [String] = [
    "1234567890-=",
    "qwertyuiop[]",
    "asdfghjkl;'",
    "zxcvbnm,./",
  ]

  private static let leetSubstitutions: [Character: Character] = [
    "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s", "!": "i",
  ]

  /// The bundled common-password list, loaded once and shared by every
  /// `SecurityAuditor` instance.
  private static let commonPasswords: Set<String> = loadCommonPasswords()

  public init() {}

  // MARK: - Auditing

  /// Audits `inputs` and returns the issues found for each id.
  ///
  /// Ids with no issues (or whose ``AuditInput/hiddenWarning`` is `true`)
  /// are absent from the result rather than mapped to an empty set.
  public func audit<ID: Hashable & Sendable>(_ inputs: [AuditInput<ID>]) -> [ID: Set<SecurityIssue>] {
    var issuesByID: [ID: Set<SecurityIssue>] = [:]

    // Reuse detection groups ids by a hash of their password rather than
    // the password itself, so no structure here ever holds plaintext for
    // longer than the single line that hashes it.
    var idsByPasswordHash: [Data: [ID]] = [:]
    for input in inputs {
      let digest = SHA256.hash(data: Data(input.password.utf8))
      idsByPasswordHash[Data(digest), default: []].append(input.id)
    }
    for ids in idsByPasswordHash.values where ids.count > 1 {
      for id in ids {
        issuesByID[id, default: []].insert(.reused)
      }
    }

    for input in inputs {
      let reasons = weakPasswordReasons(for: input.password)
      if !reasons.isEmpty {
        issuesByID[input.id, default: []].insert(.weak(reasons))
      }
    }

    // A hidden warning suppresses this entry's own issues, but the entry
    // still participated in reuse grouping above, so other entries that
    // share its password are still flagged.
    for input in inputs where input.hiddenWarning {
      issuesByID.removeValue(forKey: input.id)
    }

    return issuesByID
  }

  // MARK: - Weak-password estimate

  private func weakPasswordReasons(for password: String) -> WeakPasswordReasons {
    let lowercased = password.lowercased()
    let core = strippingTrailingDigits(lowercased)
    let leetCore = leetNormalized(core)

    var reasons: WeakPasswordReasons = []

    if isCommonPassword(lowercased) || isCommonPassword(core) || isCommonPassword(leetCore) {
      reasons.insert(.commonPassword)
    }
    if isFullSequence(lowercased) || (core != lowercased && isFullSequence(core)) {
      reasons.insert(.sequence)
    }
    if isFullRepeat(lowercased) || (core != lowercased && isFullRepeat(core)) {
      reasons.insert(.repeatedCharacters)
    }
    if isFullKeyboardWalk(lowercased) || (core != lowercased && isFullKeyboardWalk(core)) {
      reasons.insert(.keyboardPattern)
    }
    if estimatedEntropyBits(of: password) < Self.lowEntropyThresholdBits {
      reasons.insert(.lowEntropy)
    }

    return reasons
  }

  private func isCommonPassword(_ s: String) -> Bool {
    Self.commonPasswords.contains(s)
  }

  /// Whether the entire string is a single ascending or descending run of
  /// consecutive Unicode scalars, e.g. `"12345678"` or `"hgfedcba"`.
  private func isFullSequence(_ s: String) -> Bool {
    let scalars = Array(s.unicodeScalars)
    guard scalars.count >= Self.patternMinimumLength else { return false }
    let pairs = zip(scalars, scalars.dropFirst())
    let ascending = pairs.allSatisfy { $1.value == $0.value + 1 }
    let descending = pairs.allSatisfy { $1.value == $0.value - 1 }
    return ascending || descending
  }

  /// Whether the entire string is one character repeated, or a short
  /// (1-3 character) block repeated end to end, e.g. `"aaaa"`,
  /// `"ababab"`, or `"abcabc"`.
  private func isFullRepeat(_ s: String) -> Bool {
    let characters = Array(s)
    guard characters.count >= 3 else { return false }
    for period in 1...min(3, characters.count / 2) {
      guard characters.count % period == 0, characters.count / period >= 2 else { continue }
      let unit = characters[0..<period]
      let tiles = stride(from: 0, to: characters.count, by: period).allSatisfy { start in
        characters[start..<start + period].elementsEqual(unit)
      }
      if tiles { return true }
    }
    return false
  }

  /// Whether the entire string is a run of physically adjacent keys on a
  /// US QWERTY keyboard, e.g. `"qwerty"` or `"zxcvbn"` (forward or
  /// reversed).
  private func isFullKeyboardWalk(_ s: String) -> Bool {
    guard s.count >= Self.patternMinimumLength else { return false }
    return Self.keyboardRows.contains { row in
      row.contains(s) || String(row.reversed()).contains(s)
    }
  }

  /// A rough character-pool-based entropy estimate: `length *
  /// log2(poolSize)`, where `poolSize` is the sum of the sizes of the
  /// character categories (lowercase, uppercase, digit, other) actually
  /// present in `password`. This doesn't account for patterns — that's
  /// what the checks above are for — only for how large the brute-force
  /// search space is once those patterns are absent.
  private func estimatedEntropyBits(of password: String) -> Double {
    guard !password.isEmpty else { return 0 }

    var hasLowercase = false
    var hasUppercase = false
    var hasDigit = false
    var hasOther = false
    for scalar in password.unicodeScalars {
      if CharacterSet.lowercaseLetters.contains(scalar) {
        hasLowercase = true
      } else if CharacterSet.uppercaseLetters.contains(scalar) {
        hasUppercase = true
      } else if CharacterSet.decimalDigits.contains(scalar) {
        hasDigit = true
      } else {
        hasOther = true
      }
    }

    var poolSize = 0
    if hasLowercase { poolSize += 26 }
    if hasUppercase { poolSize += 26 }
    if hasDigit { poolSize += 10 }
    if hasOther { poolSize += Self.symbolPoolSize }
    poolSize = max(poolSize, 1)

    return Double(password.count) * log2(Double(poolSize))
  }

  // MARK: - Normalization helpers

  private func strippingTrailingDigits(_ s: String) -> String {
    var characters = Array(s)
    while let last = characters.last, last.isNumber {
      characters.removeLast()
    }
    return String(characters)
  }

  private func leetNormalized(_ s: String) -> String {
    String(s.map { Self.leetSubstitutions[$0] ?? $0 })
  }

  // MARK: - Resource loading

  private static func loadCommonPasswords() -> Set<String> {
    guard
      let url = Bundle.module.url(forResource: "common-passwords", withExtension: "txt"),
      let contents = try? String(contentsOf: url, encoding: .utf8)
    else {
      assertionFailure("Missing bundled common-passwords.txt resource")
      return []
    }

    let entries =
      contents
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
      .map { $0.lowercased() }

    return Set(entries)
  }
}
