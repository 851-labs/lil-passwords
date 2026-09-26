import Foundation

/// A minimal `URLProtocol` stub so tests can intercept every request a `URLSession` makes and
/// return a canned response without touching the network — shared by ``CompromisedPasswordChecker``
/// (851-2458) and ``IconFetcher`` (851-2459) tests, the first two things in this package that make
/// real HTTP requests.
///
/// Each test gets its own isolated handler via ``makeSession(handler:)`` rather than a single
/// global one: `URLSessionConfiguration.httpAdditionalHeaders` stamps a random per-session token
/// onto every outgoing request, and `startLoading()` looks the handler up by that token, so
/// concurrently-running tests (Swift Testing parallelizes by default) never see each other's
/// stubbed responses.
final class StubURLProtocol: URLProtocol {
  typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

  /// Global mutable state wrapped in one `@unchecked Sendable` box (rather than a bare `static
  /// var`) so Swift 6's strict concurrency checking has a single, explicitly-synchronized home
  /// for it instead of flagging the property itself.
  private final class HandlerRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlersByToken: [String: Handler] = [:]

    func register(_ handler: @escaping Handler, forToken token: String) {
      lock.lock()
      handlersByToken[token] = handler
      lock.unlock()
    }

    func handler(forToken token: String?) -> Handler? {
      guard let token else { return nil }
      lock.lock()
      defer { lock.unlock() }
      return handlersByToken[token]
    }
  }

  private static let registry = HandlerRegistry()
  private static let tokenHeaderField = "X-StubURLProtocol-Token"

  /// Builds an ephemeral `URLSession` whose every request — regardless of host or path — is
  /// answered by `handler`, with no real network access.
  static func makeSession(handler: @escaping Handler) -> URLSession {
    let token = UUID().uuidString
    registry.register(handler, forToken: token)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    configuration.httpAdditionalHeaders = [tokenHeaderField: token]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let token = request.value(forHTTPHeaderField: Self.tokenHeaderField)
    guard let handler = Self.registry.handler(forToken: token) else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
