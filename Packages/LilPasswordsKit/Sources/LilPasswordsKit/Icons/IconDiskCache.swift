import CryptoKit
import Foundation

/// Persists fetched website icon PNGs to disk (851-2459), keyed by a hash of the domain rather
/// than the domain itself — matching ``CompromisedPasswordChecker``'s "never the plaintext on
/// disk" caution, even though a domain is far less sensitive than a password: this way the cache
/// directory's file listing alone doesn't hand out a readable list of every site this vault has
/// an account with to anything else with read access to Application Support.
///
/// Lives at `~/Library/Application Support/lil passwords/Icons/`, alongside `VaultStore`'s own
/// `defaultDatabaseURL()` directory — see that type for the same Application Support resolution
/// pattern.
public struct IconDiskCache: Sendable {
  private let directory: URL

  /// - Parameters:
  ///   - directory: Where cached icon files are read from and written to. Defaults to
  ///     ``defaultDirectory(fileManager:)``. Tests should pass a URL inside a temporary directory
  ///     instead, so each test run gets its own isolated cache.
  ///
  /// `FileManager` itself isn't stored (it isn't `Sendable`) — `.default` is safe to call from
  /// any thread per its own documentation, so every method below just reaches for it directly.
  public init(directory: URL = IconDiskCache.defaultDirectory()) {
    self.directory = directory
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
    let appSupport =
      (try? fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )) ?? fileManager.temporaryDirectory
    return
      appSupport
      .appendingPathComponent("lil passwords", isDirectory: true)
      .appendingPathComponent("Icons", isDirectory: true)
  }

  /// Reads the cached PNG for `domain`, or `nil` if nothing is cached for it yet.
  public func data(forDomain domain: String) -> Data? {
    try? Data(contentsOf: fileURL(forDomain: domain))
  }

  /// Writes `data` as the cached PNG for `domain`, overwriting any previous entry. Best-effort:
  /// a write failure (e.g. a full disk) is silently ignored, since a missing icon cache entry
  /// just means the next lookup re-fetches rather than corrupting anything.
  public func store(_ data: Data, forDomain domain: String) {
    try? data.write(to: fileURL(forDomain: domain), options: .atomic)
  }

  /// Removes the cached PNG for `domain`, if any.
  public func removeData(forDomain domain: String) {
    try? FileManager.default.removeItem(at: fileURL(forDomain: domain))
  }

  private func fileURL(forDomain domain: String) -> URL {
    directory.appendingPathComponent(Self.fileName(forDomain: domain), isDirectory: false)
  }

  /// The on-disk file name for `domain`: the lowercased domain's hex SHA-256 digest, so the same
  /// domain always maps to the same file across launches, and the name itself doesn't reveal the
  /// domain.
  static func fileName(forDomain domain: String) -> String {
    let digest = SHA256.hash(data: Data(domain.lowercased().utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "\(hex).png"
  }
}
