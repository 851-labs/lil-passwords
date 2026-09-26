import Foundation
import Testing

@testable import LilPasswordsKit

@Suite struct IconFetcherTests {
  /// A real, minimal, valid 1x1 transparent PNG — small enough to inline, but a genuine image
  /// `CGImageSourceCreateWithData` can decode, unlike an arbitrary byte string.
  static let validPNGData = Data(
    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
  )!

  private static func response(_ url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
  }

  /// Builds a fetcher whose session answers each request by path via `routes` — e.g.
  /// `["/apple-touch-icon.png": .notFound, "/favicon.ico": .image(Self.validPNGData)]` — and
  /// 404s anything not listed.
  private enum Route {
    case notFound
    case image(Data)
    case html(String)
    case oversized(Int)
  }

  private static func makeFetcher(
    routes: [String: Route],
    requestedPaths: RequestedPathsBox? = nil,
    maxResponseByteCount: Int = 2_000_000
  ) -> IconFetcher {
    let session = StubURLProtocol.makeSession { request in
      let url = request.url!
      requestedPaths?.append(url.path)
      switch routes[url.path] ?? .notFound {
      case .notFound:
        return (response(url, status: 404), Data())
      case .image(let data):
        return (response(url, status: 200), data)
      case .html(let html):
        return (response(url, status: 200), Data(html.utf8))
      case .oversized(let count):
        return (response(url, status: 200), Data(repeating: 0, count: count))
      }
    }
    return IconFetcher(session: session, maxResponseByteCount: maxResponseByteCount)
  }

  final class RequestedPathsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) {
      lock.lock()
      values.append(value)
      lock.unlock()
    }
    var all: [String] {
      lock.lock()
      defer { lock.unlock() }
      return values
    }
  }

  @Test func fetchesAppleTouchIconFirst() async {
    let fetcher = Self.makeFetcher(routes: ["/apple-touch-icon.png": .image(Self.validPNGData)])
    let data = await fetcher.fetchIconPNGData(forHost: "example.com")
    #expect(data != nil)
  }

  @Test func fallsBackToFaviconIcoWhenAppleTouchIconIsMissing() async {
    let requested = RequestedPathsBox()
    let fetcher = Self.makeFetcher(
      routes: ["/favicon.ico": .image(Self.validPNGData)],
      requestedPaths: requested
    )
    let data = await fetcher.fetchIconPNGData(forHost: "example.com")
    #expect(data != nil)
    #expect(requested.all.contains("/apple-touch-icon.png"))
    #expect(requested.all.contains("/favicon.ico"))
  }

  @Test func fallsBackToHTMLLinkIconWhenNeitherWellKnownPathExists() async {
    let html = """
      <html><head><link rel="icon" href="/static/icon-32.png"></head></html>
      """
    let fetcher = Self.makeFetcher(
      routes: [
        "/": .html(html),
        "/static/icon-32.png": .image(Self.validPNGData),
      ]
    )
    let data = await fetcher.fetchIconPNGData(forHost: "example.com")
    #expect(data != nil)
  }

  @Test func returnsNilWhenEveryCandidateFails() async {
    let fetcher = Self.makeFetcher(routes: ["/": .html("<html><head></head></html>")])
    let data = await fetcher.fetchIconPNGData(forHost: "example.com")
    #expect(data == nil)
  }

  @Test func returnsNilForAnEmptyHost() async {
    let fetcher = Self.makeFetcher(routes: [:])
    let data = await fetcher.fetchIconPNGData(forHost: "")
    #expect(data == nil)
  }

  @Test func skipsAnOversizedResponse() async {
    let fetcher = Self.makeFetcher(
      routes: ["/apple-touch-icon.png": .oversized(10)],
      maxResponseByteCount: 5
    )
    let data = await fetcher.fetchIconPNGData(forHost: "example.com")
    #expect(data == nil)
  }

  @Test func neverFollowsANonHTTPSLinkIconHref() async {
    let html = """
      <link rel="icon" href="http://example.com/insecure-icon.png">
      """
    let fetcher = Self.makeFetcher(
      routes: [
        "/": .html(html),
        "/insecure-icon.png": .image(Self.validPNGData),
      ]
    )
    let data = await fetcher.fetchIconPNGData(forHost: "example.com")
    #expect(data == nil)
  }

  @Test func wellKnownCandidateURLsAreAlwaysHTTPS() {
    let urls = IconFetcher.wellKnownCandidateURLs(forHost: "example.com")
    #expect(urls.allSatisfy { $0.scheme == "https" })
    #expect(urls.map(\.path) == ["/apple-touch-icon.png", "/favicon.ico"])
  }

  @Test func parseIconHrefFindsAPlainIconLink() {
    let html = #"<link rel="icon" href="/favicon-32.png" type="image/png">"#
    #expect(IconFetcher.parseIconHref(fromHTML: html) == "/favicon-32.png")
  }

  @Test func parseIconHrefFindsAShortcutIconLinkRegardlessOfAttributeOrder() {
    let html = #"<link href="/legacy-favicon.ico" rel="shortcut icon">"#
    #expect(IconFetcher.parseIconHref(fromHTML: html) == "/legacy-favicon.ico")
  }

  @Test func parseIconHrefIgnoresUnrelatedLinkTags() {
    let html = #"""
      <link rel="stylesheet" href="/style.css">
      <link rel="icon" href="/icon.png">
      """#
    #expect(IconFetcher.parseIconHref(fromHTML: html) == "/icon.png")
  }

  @Test func parseIconHrefReturnsNilWhenThereIsNoIconLink() {
    let html = #"<link rel="stylesheet" href="/style.css">"#
    #expect(IconFetcher.parseIconHref(fromHTML: html) == nil)
  }

  @Test func normalizedPNGDataDecodesARealImageAndReencodesItAsPNG() {
    let normalized = IconFetcher.normalizedPNGData(from: Self.validPNGData, maxDimension: 64)
    #expect(normalized != nil)
    // PNG's 8-byte magic number.
    let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    #expect(normalized.map(Array.init)?.prefix(8) == ArraySlice(pngMagic))
  }

  @Test func normalizedPNGDataReturnsNilForNonImageData() {
    let normalized = IconFetcher.normalizedPNGData(from: Data("not an image".utf8), maxDimension: 64)
    #expect(normalized == nil)
  }
}
