import CoreGraphics
import Foundation
import ImageIO

#if canImport(UniformTypeIdentifiers)
  import UniformTypeIdentifiers
#endif

/// Fetches a website's icon over **HTTPS only** (851-2459), trying — in order — the most likely
/// place a real icon lives:
///
/// 1. `https://{host}/apple-touch-icon.png` — usually the highest-resolution icon a site ships.
/// 2. `https://{host}/favicon.ico`
/// 3. Whatever `<link rel="icon" ...>` (or `rel="shortcut icon"`) the site's homepage HTML
///    declares, resolved against that homepage URL.
///
/// Opt-in (``AppSettings/showWebsiteIcons``), off by default: fetching an icon tells that site
/// (and anything on the network path to it) that this Mac has an account there, which is exactly
/// the kind of request the MVP's local-first design avoids without explicit consent.
///
/// Every candidate is decoded and re-encoded as PNG, capped to ``maxDimension`` on its longer
/// side, before this type ever hands data back to a caller — so a caller never has to trust (or
/// separately validate) whatever bytes a remote server sent, and a hostile or broken response
/// (an oversized image, a non-image body, a corrupt file) simply fails to decode and is treated
/// as "no icon" rather than propagated.
public actor IconFetcher {
  private let session: URLSession

  /// Responses larger than this are discarded without attempting to decode them — a coarse
  /// safety cap, not a byte-exact streaming limit (this actor reads the full response body via
  /// `URLSession.data(for:)` before checking its size), but enough to stop a misbehaving or
  /// malicious server from handing back an enormous body in place of a small icon.
  private let maxResponseByteCount: Int

  /// The longer side, in pixels, every returned icon is downsampled to. Icons are small UI
  /// elements (28-64pt @ up to 2x in this app), so there's no reason to keep, or re-encode, a
  /// multi-hundred-pixel source image at full resolution.
  private let maxDimension: CGFloat

  /// - Parameters:
  ///   - session: Injected so tests can stub every request with `URLProtocol` and never touch the
  ///     network (851-2459). Defaults to an ephemeral session (no cookies, no shared cache).
  public init(
    session: URLSession = IconFetcher.makeDefaultSession(),
    maxResponseByteCount: Int = 2_000_000,
    maxDimension: CGFloat = 256
  ) {
    self.session = session
    self.maxResponseByteCount = maxResponseByteCount
    self.maxDimension = maxDimension
  }

  public static func makeDefaultSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 8
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
  }

  /// Fetches, decodes, and normalizes the icon for `host` (a bare domain, e.g. `"github.com"`,
  /// not a full URL). Returns `nil` if `host` is empty, every candidate request fails (offline,
  /// timeout, non-200), or nothing that came back could be decoded as an image.
  public func fetchIconPNGData(forHost host: String) async -> Data? {
    guard !host.isEmpty else { return nil }

    for url in Self.wellKnownCandidateURLs(forHost: host) {
      if let data = await fetchAndNormalize(url) {
        return data
      }
    }

    if let linkURL = await fetchLinkIconURL(forHost: host), let data = await fetchAndNormalize(linkURL) {
      return data
    }

    return nil
  }

  /// `apple-touch-icon.png`, then `favicon.ico` — both always HTTPS regardless of what scheme, if
  /// any, a caller's stored website URL used.
  static func wellKnownCandidateURLs(forHost host: String) -> [URL] {
    [
      URL(string: "https://\(host)/apple-touch-icon.png"),
      URL(string: "https://\(host)/favicon.ico"),
    ].compactMap { $0 }
  }

  /// Fetches `https://{host}/` and looks for an `<link rel="icon">`/`<link rel="shortcut icon">`
  /// href, resolved against that URL. Returns `nil` on any failure, or if the resolved URL isn't
  /// `https`.
  private func fetchLinkIconURL(forHost host: String) async -> URL? {
    guard let pageURL = URL(string: "https://\(host)/") else { return nil }
    guard let html = await fetchString(pageURL) else { return nil }
    guard let href = Self.parseIconHref(fromHTML: html) else { return nil }
    guard let resolved = URL(string: href, relativeTo: pageURL)?.absoluteURL else { return nil }
    guard resolved.scheme?.lowercased() == "https" else { return nil }
    return resolved
  }

  /// Finds the `href` of the first `<link>` tag whose `rel` attribute contains `icon`
  /// (case-insensitively) — matches `rel="icon"`, `rel="shortcut icon"`, and `rel="apple-touch-icon"`
  /// alike, in whatever attribute order the page happens to use. Deliberately a regex over the raw
  /// HTML rather than a full parser: this only ever needs one attribute off one kind of tag, and a
  /// real HTML parser is a much bigger dependency than 851-2459 calls for.
  static func parseIconHref(fromHTML html: String) -> String? {
    guard
      let linkTagRegex = try? NSRegularExpression(
        pattern: #"<link\b[^>]*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
      ),
      let relRegex = try? NSRegularExpression(pattern: #"rel\s*=\s*["']([^"']*)["']"#, options: [.caseInsensitive]),
      let hrefRegex = try? NSRegularExpression(pattern: #"href\s*=\s*["']([^"']*)["']"#, options: [.caseInsensitive])
    else { return nil }

    let nsHTML = html as NSString
    let linkTags = linkTagRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
    for match in linkTags {
      let tag = nsHTML.substring(with: match.range)
      let nsTag = tag as NSString
      guard let relMatch = relRegex.firstMatch(in: tag, range: NSRange(location: 0, length: nsTag.length)),
        nsTag.substring(with: relMatch.range(at: 1)).lowercased().contains("icon")
      else { continue }
      guard let hrefMatch = hrefRegex.firstMatch(in: tag, range: NSRange(location: 0, length: nsTag.length)) else {
        continue
      }
      let href = nsTag.substring(with: hrefMatch.range(at: 1))
      if !href.isEmpty { return href }
    }
    return nil
  }

  /// GETs `url` and returns its body decoded as UTF-8 text, or `nil` on any failure (including a
  /// non-200 response, a body over ``maxResponseByteCount``, or non-UTF-8 content).
  private func fetchString(_ url: URL) async -> String? {
    guard let data = await fetchData(url) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// GETs `url`, decodes the body as an image, and re-encodes it as PNG capped to
  /// ``maxDimension``. Returns `nil` on any failure.
  private func fetchAndNormalize(_ url: URL) async -> Data? {
    guard let data = await fetchData(url) else { return nil }
    return Self.normalizedPNGData(from: data, maxDimension: maxDimension)
  }

  /// GETs `url` over HTTPS and returns its raw body, or `nil` if the scheme isn't https, the
  /// request fails, the response isn't a 200, or the body exceeds ``maxResponseByteCount``.
  private func fetchData(_ url: URL) async -> Data? {
    guard url.scheme?.lowercased() == "https" else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
      guard data.count <= maxResponseByteCount else { return nil }
      return data
    } catch {
      return nil
    }
  }

  /// Decodes `rawData` as an image (PNG, ICO, JPEG, or anything else `ImageIO` recognizes),
  /// downsamples its sharpest available frame (see ``largestFrameIndex(in:)``) so its longer side
  /// is at most `maxDimension` pixels, and re-encodes the result as PNG. Returns `nil` if
  /// `rawData` isn't a decodable image.
  ///
  /// `nonisolated` (and not actor-isolated state) so tests can call it directly with fixture
  /// bytes without going through a network stub at all.
  nonisolated static func normalizedPNGData(from rawData: Data, maxDimension: CGFloat) -> Data? {
    guard let source = CGImageSourceCreateWithData(rawData as CFData, nil) else { return nil }
    let thumbnailOptions =
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        kCGImageSourceCreateThumbnailWithTransform: true,
      ] as CFDictionary
    let frameIndex = largestFrameIndex(in: source)
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, frameIndex, thumbnailOptions) else {
      return nil
    }

    let mutableData = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(mutableData, Self.pngUTType, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return mutableData as Data
  }

  /// The index, among every frame/representation `source` contains, whose pixel dimensions are
  /// largest — so it stays sharp at 40pt @2x (851-2467). A multi-size `.ico` (the common shape of
  /// a real `favicon.ico`, which often embeds 16/32/48/256px variants in a single file) picks its
  /// biggest frame instead of whatever index `ImageIO` happens to list first, which isn't
  /// guaranteed to be the largest. Single-frame sources (a plain PNG/JPEG `apple-touch-icon.png`,
  /// or whatever a page's `<link rel="icon">` points to) just return `0`, their only index.
  nonisolated static func largestFrameIndex(in source: CGImageSource) -> Int {
    let count = CGImageSourceGetCount(source)
    guard count > 1 else { return 0 }

    var bestIndex = 0
    var bestArea: Double = 0
    for index in 0..<count {
      guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
        continue
      }
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
      let area = width * height
      if area > bestArea {
        bestArea = area
        bestIndex = index
      }
    }
    return bestIndex
  }

  private static var pngUTType: CFString {
    #if canImport(UniformTypeIdentifiers)
      if #available(macOS 11.0, *) {
        return UTType.png.identifier as CFString
      }
    #endif
    return "public.png" as CFString
  }
}
