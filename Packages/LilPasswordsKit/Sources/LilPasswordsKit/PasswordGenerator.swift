import Security

/// Generates random passwords.
///
/// The default format mirrors Apple's "Strong Password" suggestion: three
/// six-letter lowercase groups joined by hyphens, with exactly one letter
/// uppercased and one letter replaced by a digit, e.g. `abcdef-ghijk2-lmNopq`.
/// Custom passwords with a configurable length and character categories
/// (including a "no symbols" variant) are also supported.
///
/// Randomness is drawn from an injectable ``RandomSource`` so callers — and
/// tests — can supply a deterministic source instead of the system CSPRNG.
public struct PasswordGenerator: Sendable {
  /// A source of random bytes, injectable so callers can substitute a
  /// deterministic generator (for tests) in place of the system CSPRNG.
  public struct RandomSource: Sendable {
    private let generate: @Sendable (Int) -> [UInt8]

    /// Creates a source backed by `generate`, which must return exactly
    /// `count` random bytes.
    public init(_ generate: @escaping @Sendable (Int) -> [UInt8]) {
      self.generate = generate
    }

    func bytes(_ count: Int) -> [UInt8] {
      generate(count)
    }

    /// The default source, backed by `SecRandomCopyBytes`.
    public static let system = RandomSource { count in
      var bytes = [UInt8](repeating: 0, count: count)
      let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
      precondition(status == errSecSuccess, "SecRandomCopyBytes failed with OSStatus \(status)")
      return bytes
    }
  }

  /// Character categories a custom password can draw from.
  public struct CharacterCategories: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
      self.rawValue = rawValue
    }

    public static let lowercase = CharacterCategories(rawValue: 1 << 0)
    public static let uppercase = CharacterCategories(rawValue: 1 << 1)
    public static let digits = CharacterCategories(rawValue: 1 << 2)
    public static let symbols = CharacterCategories(rawValue: 1 << 3)

    /// Every supported category.
    public static let all: CharacterCategories = [.lowercase, .uppercase, .digits, .symbols]

    /// Letters and digits only — the "no special characters" variant.
    public static let noSymbols: CharacterCategories = [.lowercase, .uppercase, .digits]

    fileprivate var characters: [Character] {
      var result: [Character] = []
      if contains(.lowercase) { result += Alphabet.lowercase }
      if contains(.uppercase) { result += Alphabet.uppercase }
      if contains(.digits) { result += Alphabet.digits }
      if contains(.symbols) { result += Alphabet.symbols }
      return result
    }
  }

  /// The shape of password to generate.
  public enum Format: Sendable, Equatable {
    /// Apple's "Strong Password" format: three six-letter lowercase groups
    /// joined by hyphens, with exactly one letter uppercased and one letter
    /// replaced by a digit, e.g. `abcdef-ghijk2-lmNopq`.
    case appleStrong

    /// A password of `length` characters drawn uniformly at random from
    /// `characterCategories`.
    case custom(length: Int, characterCategories: CharacterCategories = .all)
  }

  /// Thrown when the requested `Format` can't produce a password, e.g. a
  /// non-positive length or an empty character category set.
  public struct GenerationError: Error, Equatable, CustomStringConvertible {
    public let description: String
  }

  private enum Alphabet {
    static let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
    static let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let digits = Array("0123456789")
    // A conservative symbol set that avoids quoting/escaping surprises
    // (no quotes, backslashes, or whitespace) when passwords are pasted
    // into shells, URLs, or config files.
    static let symbols = Array("!@#$%^&*-_=+?")
  }

  private static let appleStrongGroupCount = 3
  private static let appleStrongGroupLength = 6

  private let randomSource: RandomSource

  /// Creates a generator that draws randomness from `randomSource`, which
  /// defaults to the system CSPRNG (`SecRandomCopyBytes`).
  public init(randomSource: RandomSource = .system) {
    self.randomSource = randomSource
  }

  /// Generates a password in the given format.
  ///
  /// - Throws: ``GenerationError`` if `format` is `.custom` with a
  ///   non-positive length or an empty character category set.
  public func generate(format: Format = .appleStrong) throws -> String {
    switch format {
    case .appleStrong:
      return generateAppleStrong()
    case .custom(let length, let characterCategories):
      return try generateCustom(length: length, characterCategories: characterCategories)
    }
  }

  private func generateAppleStrong() -> String {
    let totalLetters = Self.appleStrongGroupCount * Self.appleStrongGroupLength
    var letters = (0..<totalLetters).map { _ in randomElement(Alphabet.lowercase) }

    let uppercaseIndex = randomIndex(lessThan: totalLetters)
    var digitIndex = randomIndex(lessThan: totalLetters)
    while digitIndex == uppercaseIndex {
      digitIndex = randomIndex(lessThan: totalLetters)
    }

    letters[uppercaseIndex] = Character(letters[uppercaseIndex].uppercased())
    letters[digitIndex] = randomElement(Alphabet.digits)

    return stride(from: 0, to: totalLetters, by: Self.appleStrongGroupLength)
      .map { start in String(letters[start..<start + Self.appleStrongGroupLength]) }
      .joined(separator: "-")
  }

  private func generateCustom(length: Int, characterCategories: CharacterCategories) throws -> String {
    guard length > 0 else {
      throw GenerationError(description: "Password length must be greater than zero.")
    }
    let alphabet = characterCategories.characters
    guard !alphabet.isEmpty else {
      throw GenerationError(description: "At least one character category must be selected.")
    }
    return String((0..<length).map { _ in randomElement(alphabet) })
  }

  private func randomElement<T>(_ collection: [T]) -> T {
    collection[randomIndex(lessThan: collection.count)]
  }

  /// Returns a uniformly distributed index in `0..<bound`, drawing one byte
  /// at a time and rejecting values that would skew the distribution (plain
  /// modulo of a fixed-width byte is biased whenever `bound` doesn't evenly
  /// divide 256).
  private func randomIndex(lessThan bound: Int) -> Int {
    precondition(bound > 0 && bound <= 256, "randomIndex only supports bounds in 1...256")
    let limit = 256 - (256 % bound)
    while true {
      let byte = Int(randomSource.bytes(1)[0])
      if byte < limit {
        return byte % bound
      }
    }
  }
}
