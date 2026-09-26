import AppKit
import LilPasswordsKit

/// Loads a real website icon (851-2459) for an item's primary website host, for the 4 places the
/// ticket calls out — the item list, the detail pane, the menu bar item detail, and the New
/// Password sheet — behind the opt-in ``AppSettings/showWebsiteIcons`` switch (off by default).
///
/// Every caller is expected to already be showing ``MonogramIcon`` synchronously before calling
/// ``loadIcon(forHost:dimension:onIconLoaded:)`` — this only ever calls back if a real icon was
/// actually found, so "no callback" just means "keep showing the monogram."
///
/// Wraps a single process-wide ``IconStore`` (an actor) so the list, detail pane, menu bar, and
/// New Password sheet all share one in-memory/on-disk cache instead of each fetching and caching
/// independently. The image handed back through `onIconLoaded` is already run through
/// ``WebsiteIconRenderer`` (851-2467) — clipped to `MonogramIcon`'s rounded square, tiled if it's
/// transparent-edged or too small, hairline-bordered in light mode — so no call site has to do
/// that itself.
@MainActor
enum WebsiteIconLoader {
  private static let store = IconStore()

  /// Starts an async lookup for `host` (e.g. `item.websites.first?.host`), calling `onIconLoaded`
  /// back on the main actor only if a real icon was found. Returns `nil` immediately — without
  /// touching the network or the cache — when icons are turned off or `host` is empty/`nil`.
  ///
  /// - Parameter dimension: The side length, in points, the caller is displaying the icon at —
  ///   the same value already passed to `MonogramIcon.icon(for:dimension:)` at each call site.
  ///   Drives ``WebsiteIconRenderer``'s corner radius and its small-vs-sharp tile decision.
  ///
  /// The returned task checks `Task.isCancelled` itself before calling back, so it's safe for a
  /// caller to either explicitly cancel it (e.g. on cell reuse, or when the displayed item changes
  /// before the fetch completes) or just drop the reference and let it finish harmlessly.
  @discardableResult
  static func loadIcon(
    forHost host: String?,
    dimension: CGFloat,
    onIconLoaded: @escaping @MainActor (NSImage) -> Void
  ) -> Task<Void, Never>? {
    guard AppSettings.shared.showWebsiteIcons else { return nil }
    guard let host, !host.isEmpty else { return nil }

    return Task { @MainActor in
      let data = await store.icon(forHost: host)
      guard !Task.isCancelled, let data, let image = NSImage(data: data) else { return }
      onIconLoaded(WebsiteIconRenderer.render(image, dimension: dimension))
    }
  }
}
