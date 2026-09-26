import Testing

@testable import LilPasswordsKit

/// Feeds a fixed, cycling sequence of bytes to a `PasswordGenerator`, making
/// its output fully deterministic for a given call order.
private final class ByteFeed: @unchecked Sendable {
  private let bytes: [UInt8]
  private var index = 0

  init(_ bytes: [UInt8]) {
    precondition(!bytes.isEmpty)
    self.bytes = bytes
  }

  func next(_ count: Int) -> [UInt8] {
    let drawn = (0..<count).map { bytes[(index + $0) % bytes.count] }
    index += count
    return drawn
  }

  var randomSource: PasswordGenerator.RandomSource {
    PasswordGenerator.RandomSource { [self] count in next(count) }
  }
}

@Suite struct PasswordGeneratorTests {

  // MARK: - Apple strong format

  @Test func appleStrongFormatStructure() throws {
    let generator = PasswordGenerator()
    for _ in 0..<200 {
      let password = try generator.generate()
      let groups = password.split(separator: "-", omittingEmptySubsequences: false)
      #expect(groups.count == 3)
      #expect(groups.allSatisfy { $0.count == 6 })
      #expect(password.count == 20)

      let letters = groups.joined()
      let uppercaseCount = letters.filter { $0.isUppercase }.count
      let digitCount = letters.filter { $0.isNumber }.count
      let lowercaseCount = letters.filter { $0.isLowercase }.count

      #expect(uppercaseCount == 1)
      #expect(digitCount == 1)
      #expect(lowercaseCount == 16)
      #expect(letters.allSatisfy { $0.isLetter || $0.isNumber })
    }
  }

  @Test func appleStrongFormatIsDeterministicGivenTheSameRandomSource() throws {
    // Bytes below every rejection-sampling limit used by the generator
    // (26, 18, and 10 all reject at >= 234), so each call consumes exactly
    // one byte and `byte % bound` is easy to trace by hand:
    //   18 letters:  a b c d e f g h i j k l m n o p q r  (bytes 0...17)
    //   uppercase index:  8 % 18 = 8  -> the 'i' becomes 'I'
    //   digit index:      3 % 18 = 3  -> the 'd' becomes a digit
    //   digit value:      7 % 10 = 7  -> '7'
    let feed = ByteFeed([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 8, 3, 7])
    let generator = PasswordGenerator(randomSource: feed.randomSource)

    #expect(try generator.generate() == "abc7ef-ghIjkl-mnopqr")
  }

  @Test func appleStrongFormatRedrawsOnDigitUppercaseCollision() throws {
    // uppercaseIndex draws 8 % 18 = 8. digitIndex's first draw is also 8,
    // which collides, so the generator must redraw; the redraw of 3 % 18 = 3
    // is then used.
    let feed = ByteFeed([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 8, 8, 3, 7])
    let generator = PasswordGenerator(randomSource: feed.randomSource)

    #expect(try generator.generate() == "abc7ef-ghIjkl-mnopqr")
  }

  // MARK: - Rejection sampling

  @Test func rejectsOutOfRangeBytesToAvoidModuloBias() throws {
    // Digits use bound 10, so the rejection limit is 250 (256 - 256 % 10).
    // 255 must be rejected and redrawn rather than folded in via modulo.
    let feed = ByteFeed([255, 255, 7])
    let generator = PasswordGenerator(randomSource: feed.randomSource)

    #expect(try generator.generate(format: .custom(length: 1, characterCategories: .digits)) == "7")
  }

  // MARK: - Custom format

  @Test func customFormatHasRequestedLength() throws {
    let generator = PasswordGenerator()
    for length in [1, 8, 16, 32, 64] {
      let password = try generator.generate(format: .custom(length: length))
      #expect(password.count == length)
    }
  }

  @Test func noSymbolsVariantContainsOnlyLettersAndDigits() throws {
    let generator = PasswordGenerator()
    let password = try generator.generate(format: .custom(length: 500, characterCategories: .noSymbols))
    #expect(password.allSatisfy { $0.isLetter || $0.isNumber })
  }

  @Test func characterCategoriesRestrictTheAlphabet() throws {
    let generator = PasswordGenerator()

    let digitsOnly = try generator.generate(format: .custom(length: 200, characterCategories: .digits))
    #expect(digitsOnly.allSatisfy { $0.isNumber })

    let lettersOnly = try generator.generate(
      format: .custom(length: 200, characterCategories: [.lowercase, .uppercase])
    )
    #expect(lettersOnly.allSatisfy { $0.isLetter })

    let symbolsOnly = try generator.generate(format: .custom(length: 200, characterCategories: .symbols))
    #expect(symbolsOnly.allSatisfy { !$0.isLetter && !$0.isNumber })
  }

  @Test func zeroLengthThrows() {
    let generator = PasswordGenerator()
    #expect(throws: PasswordGenerator.GenerationError.self) {
      try generator.generate(format: .custom(length: 0))
    }
  }

  @Test func emptyCharacterCategoriesThrows() {
    let generator = PasswordGenerator()
    #expect(throws: PasswordGenerator.GenerationError.self) {
      try generator.generate(format: .custom(length: 10, characterCategories: []))
    }
  }

  // MARK: - Distribution

  @Test func appleStrongLetterPositionsAreRoughlyUniform() throws {
    // Every position among the 18 letters should be picked as the uppercase
    // slot with roughly equal frequency. A biased implementation (e.g. an
    // off-by-one in the index range, or a modulo without rejection sampling)
    // would show up as a position that's never — or wildly more often —
    // selected.
    let generator = PasswordGenerator()
    var uppercasePositionCounts = [Int](repeating: 0, count: 18)

    let sampleCount = 3600
    for _ in 0..<sampleCount {
      let letters = try generator.generate().filter { $0 != "-" }
      let position = letters.firstIndex { $0.isUppercase }!
      uppercasePositionCounts[letters.distance(from: letters.startIndex, to: position)] += 1
    }

    let mean = Double(sampleCount) / 18.0
    for count in uppercasePositionCounts {
      #expect(Double(count) > mean * 0.4)
      #expect(Double(count) < mean * 1.8)
    }
  }

  @Test func customFormatCharacterFrequencyIsRoughlyUniform() throws {
    let generator = PasswordGenerator()
    let password = try generator.generate(format: .custom(length: 5400, characterCategories: .noSymbols))

    var counts: [Character: Int] = [:]
    for character in password {
      counts[character, default: 0] += 1
    }

    let alphabetSize = 26 + 26 + 10
    #expect(counts.count == alphabetSize)

    let mean = Double(password.count) / Double(alphabetSize)
    for (_, count) in counts {
      #expect(Double(count) > mean * 0.4)
      #expect(Double(count) < mean * 1.8)
    }
  }
}
