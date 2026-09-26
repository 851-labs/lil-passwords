import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct IconDiskCacheTests {
  /// Each test gets its own throwaway directory so tests can't see each other's cached files.
  private func makeCache() -> (cache: IconDiskCache, directory: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    return (IconDiskCache(directory: directory), directory)
  }

  @Test func returnsNilForADomainThatWasNeverStored() {
    let (cache, _) = makeCache()
    #expect(cache.data(forDomain: "example.com") == nil)
  }

  @Test func roundTripsStoredData() {
    let (cache, _) = makeCache()
    let data = Data("fake-png-bytes".utf8)
    cache.store(data, forDomain: "example.com")
    #expect(cache.data(forDomain: "example.com") == data)
  }

  @Test func isCaseInsensitiveOnTheDomain() {
    let (cache, _) = makeCache()
    let data = Data("fake-png-bytes".utf8)
    cache.store(data, forDomain: "Example.com")
    #expect(cache.data(forDomain: "example.com") == data)
  }

  @Test func overwritesAPreviousEntryForTheSameDomain() {
    let (cache, _) = makeCache()
    cache.store(Data("first".utf8), forDomain: "example.com")
    cache.store(Data("second".utf8), forDomain: "example.com")
    #expect(cache.data(forDomain: "example.com") == Data("second".utf8))
  }

  @Test func removeDataDropsTheEntry() {
    let (cache, _) = makeCache()
    cache.store(Data("first".utf8), forDomain: "example.com")
    cache.removeData(forDomain: "example.com")
    #expect(cache.data(forDomain: "example.com") == nil)
  }

  @Test func differentDomainsDoNotCollide() {
    let (cache, _) = makeCache()
    cache.store(Data("a".utf8), forDomain: "a.com")
    cache.store(Data("b".utf8), forDomain: "b.com")
    #expect(cache.data(forDomain: "a.com") == Data("a".utf8))
    #expect(cache.data(forDomain: "b.com") == Data("b".utf8))
  }

  @Test func fileNameNeverContainsTheDomainItself() {
    let fileName = IconDiskCache.fileName(forDomain: "example.com")
    #expect(!fileName.contains("example"))
    #expect(fileName.hasSuffix(".png"))
  }

  @Test func fileNameIsStableAndCaseInsensitive() {
    #expect(IconDiskCache.fileName(forDomain: "example.com") == IconDiskCache.fileName(forDomain: "example.com"))
    #expect(IconDiskCache.fileName(forDomain: "example.com") == IconDiskCache.fileName(forDomain: "Example.COM"))
  }

  @Test func createsItsDirectoryUpFront() {
    let (_, directory) = makeCache()
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
  }
}
