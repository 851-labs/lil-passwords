import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct IconStoreTests {
  private static let validPNGData = IconFetcherTests.validPNGData

  private final class RequestCountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
      lock.lock()
      count += 1
      lock.unlock()
    }
    var value: Int {
      lock.lock()
      defer { lock.unlock() }
      return count
    }
  }

  /// A fetcher whose one and only route (`/apple-touch-icon.png`) either always succeeds or
  /// always 404s, counting how many real requests it actually received.
  private static func makeFetcher(succeeds: Bool, requestCount: RequestCountBox) -> IconFetcher {
    let session = StubURLProtocol.makeSession { request in
      requestCount.increment()
      let url = request.url!
      guard succeeds, url.path == "/apple-touch-icon.png" else {
        return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
      }
      return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, validPNGData)
    }
    return IconFetcher(session: session)
  }

  private func makeStore(succeeds: Bool, requestCount: RequestCountBox = RequestCountBox()) -> (
    store: IconStore, requestCount: RequestCountBox
  ) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = IconStore(
      fetcher: Self.makeFetcher(succeeds: succeeds, requestCount: requestCount),
      diskCache: IconDiskCache(directory: directory)
    )
    return (store, requestCount)
  }

  @Test func fetchesAndReturnsAnIconThatExists() async {
    let (store, _) = makeStore(succeeds: true)
    let data = await store.icon(forHost: "example.com")
    #expect(data != nil)
  }

  @Test func returnsNilWhenNoIconIsAvailable() async {
    let (store, _) = makeStore(succeeds: false)
    let data = await store.icon(forHost: "example.com")
    #expect(data == nil)
  }

  @Test func returnsNilImmediatelyForAnEmptyHost() async {
    let (store, requestCount) = makeStore(succeeds: true)
    let data = await store.icon(forHost: "")
    #expect(data == nil)
    #expect(requestCount.value == 0)
  }

  @Test func cachesAPositiveResultInMemoryWithoutARepeatFetch() async {
    let (store, requestCount) = makeStore(succeeds: true)
    _ = await store.icon(forHost: "example.com")
    let countAfterFirst = requestCount.value
    _ = await store.icon(forHost: "example.com")
    #expect(requestCount.value == countAfterFirst)
  }

  @Test func cachesANegativeResultWithoutARepeatFetch() async {
    let (store, requestCount) = makeStore(succeeds: false)
    _ = await store.icon(forHost: "example.com")
    let countAfterFirst = requestCount.value
    _ = await store.icon(forHost: "example.com")
    #expect(requestCount.value == countAfterFirst)
  }

  @Test func aFreshStoreReadsAPreviouslyPersistedDiskCacheWithoutFetching() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let diskCache = IconDiskCache(directory: directory)
    diskCache.store(Self.validPNGData, forDomain: "example.com")

    let requestCount = RequestCountBox()
    let store = IconStore(fetcher: Self.makeFetcher(succeeds: false, requestCount: requestCount), diskCache: diskCache)

    let data = await store.icon(forHost: "example.com")
    #expect(data == Self.validPNGData)
    #expect(requestCount.value == 0)
  }

  @Test func isCaseInsensitiveOnTheHost() async {
    let (store, requestCount) = makeStore(succeeds: true)
    _ = await store.icon(forHost: "Example.com")
    let countAfterFirst = requestCount.value
    _ = await store.icon(forHost: "example.com")
    #expect(requestCount.value == countAfterFirst)
  }
}
