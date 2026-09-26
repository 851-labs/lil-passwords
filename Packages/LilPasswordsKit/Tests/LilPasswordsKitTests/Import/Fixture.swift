import Foundation

/// Locates the CSV fixture files bundled into the test target's resources.
enum Fixture {
  enum FixtureError: Error {
    case notFound(name: String)
  }

  static func url(_ name: String, extension ext: String = "csv") throws -> URL {
    guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
      throw FixtureError.notFound(name: name)
    }
    return url
  }

  static func text(_ name: String, extension ext: String = "csv") throws -> String {
    try String(contentsOf: try url(name, extension: ext), encoding: .utf8)
  }
}
