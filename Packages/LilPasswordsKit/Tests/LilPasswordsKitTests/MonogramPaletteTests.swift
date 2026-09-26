import Testing

@testable import LilPasswordsKit

@Suite struct MonogramPaletteTests {

  // MARK: - Stability for known inputs

  // Fixed expected indices for a 12-color palette (App's `MonogramIcon.palette.count`), computed
  // independently via FNV-1a over each title's lowercased UTF-8 bytes. These are regression
  // fixtures: the whole point of `MonogramPalette` is that a given (title, paletteCount) pair
  // always maps to the same index, across launches, platforms, and Swift versions — unlike the
  // `abs(title.hashValue)` this replaced, which is reseeded randomly every process launch. If this
  // test ever needs its expected values updated, every previously-shipped build's monogram colors
  // just silently changed underneath users, which is exactly the bug this type exists to prevent.
  @Test(
    arguments: [
      ("Amazon", 5),
      ("Apple", 3),
      ("GitHub", 6),
      ("1Password", 9),
      ("", 5),
      ("🐧Penguin", 7),
      ("Àlex", 7),
      ("zzzzzzzzzzzzzzzzzzzz", 1),
    ]
  )
  func knownInputsMapToFixedIndices(title: String, expectedIndex: Int) {
    #expect(MonogramPalette.colorIndex(for: title, paletteCount: 12) == expectedIndex)
  }

  @Test func sameTitleAlwaysReturnsTheSameIndex() {
    let title = "Consistency Check"
    let first = MonogramPalette.colorIndex(for: title, paletteCount: 12)
    for _ in 0..<50 {
      #expect(MonogramPalette.colorIndex(for: title, paletteCount: 12) == first)
    }
  }

  // MARK: - Case insensitivity

  @Test func caseVariantsOfTheSameTitleMapToTheSameIndex() {
    let lower = MonogramPalette.colorIndex(for: "amazon", paletteCount: 12)
    let upper = MonogramPalette.colorIndex(for: "AMAZON", paletteCount: 12)
    let mixed = MonogramPalette.colorIndex(for: "AmAzOn", paletteCount: 12)
    #expect(lower == upper)
    #expect(lower == mixed)
  }

  // MARK: - Range

  @Test(arguments: ["", "a", "Amazon", "🐧", String(repeating: "x", count: 500)])
  func indexIsAlwaysWithinPaletteBounds(title: String) {
    for paletteCount in [1, 2, 12, 37] {
      let index = MonogramPalette.colorIndex(for: title, paletteCount: paletteCount)
      #expect(index >= 0)
      #expect(index < paletteCount)
    }
  }

  // MARK: - No signed-overflow trap (the bug this replaced: `abs(Int.min)` traps)

  @Test func extremeInputsDoNotCrash() {
    // A long input pushes the running FNV-1a hash through many multiply/xor iterations, and would
    // be exactly the kind of input that could surface an overflow trap if the wrapping `&*` below
    // were ever accidentally changed to a checked `*`.
    let title = String(repeating: "x", count: 10_000)
    let index = MonogramPalette.colorIndex(for: title, paletteCount: 12)
    #expect(index >= 0 && index < 12)
  }
}
