import Foundation

/// The single entry point 851-2459's UI wiring calls: combines ``IconFetcher`` (network) and
/// ``IconDiskCache`` (persistence) with an in-memory cache — including a negative cache, so a
/// domain with no fetchable icon isn't re-requested from the network every time its row scrolls
/// back into view — behind one `icon(forHost:)` call.
///
/// An `actor` so concurrent lookups for the same or different hosts (the list, the detail pane,
/// the menu bar extra, and the New Password sheet can all be alive and requesting icons at once)
/// never race on the in-memory caches.
public actor IconStore {
  private let fetcher: IconFetcher
  private let diskCache: IconDiskCache

  /// Domain → PNG data, for domains a fetch has already resolved to a real icon this launch.
  private var memoryCache: [String: Data] = [:]

  /// Domains a fetch has already confirmed have no available icon this launch, so `icon(forHost:)`
  /// can return `nil` immediately instead of repeating the same three failed requests.
  private var noIconDomains: Set<String> = []

  public init(fetcher: IconFetcher = IconFetcher(), diskCache: IconDiskCache = IconDiskCache()) {
    self.fetcher = fetcher
    self.diskCache = diskCache
  }

  /// Returns the cached or freshly-fetched icon PNG for `host`, or `nil` if none is available.
  /// Checks, in order: the in-memory cache, the negative cache, the on-disk cache, and finally a
  /// real network fetch via ``IconFetcher`` — the only step that can actually reach the network,
  /// and only reached once per domain per app launch (a positive or negative result is cached
  /// either way).
  public func icon(forHost host: String) async -> Data? {
    let key = host.lowercased()
    guard !key.isEmpty else { return nil }

    if let cached = memoryCache[key] { return cached }
    if noIconDomains.contains(key) { return nil }
    if let disk = diskCache.data(forDomain: key) {
      memoryCache[key] = disk
      return disk
    }

    guard let fetched = await fetcher.fetchIconPNGData(forHost: key) else {
      noIconDomains.insert(key)
      return nil
    }
    memoryCache[key] = fetched
    diskCache.store(fetched, forDomain: key)
    return fetched
  }
}
