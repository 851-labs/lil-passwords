import Foundation

/// "Recently Deleted" retention: how long a soft-deleted item (``PasswordItem/deletedAt`` set via
/// `VaultStoring.delete(id:)`) sits around before `VaultStoring.purgeExpired(now:)` is allowed to
/// erase it for good. Matches Apple Passwords' own 30-day window; see
/// `docs/adr/0003-vaultstore.md` for the soft-delete/purge split this builds on.
extension PasswordItem {
  /// The retention window itself. `VaultStoring.purgeExpired(now:)` purges anything deleted more
  /// than this long ago; ``daysRemaining(now:)`` is the same window expressed for the UI.
  public static let recentlyDeletedRetentionPeriod: TimeInterval = 30 * 24 * 60 * 60

  /// Full days left in "Recently Deleted" before this item becomes eligible for permanent purge,
  /// or `nil` if it isn't currently deleted (``deletedAt`` is `nil`).
  ///
  /// Rounded *up*: an item deleted moments ago reads as the full 30 days remaining rather than
  /// 29, and the value never goes negative once the window has elapsed — it clamps to `0` and
  /// stays there until `purgeExpired(now:)` actually runs and removes the item. `now` is a
  /// parameter (defaulting to `Date()`) so callers — the Recently Deleted UI (851-2420) and tests
  /// alike — can drive it with a fixed clock instead of the wall clock.
  public func daysRemaining(now: Date = Date()) -> Int? {
    guard let deletedAt else { return nil }
    let remaining = Self.recentlyDeletedRetentionPeriod - now.timeIntervalSince(deletedAt)
    guard remaining > 0 else { return 0 }
    let secondsPerDay: TimeInterval = 24 * 60 * 60
    return Int((remaining / secondsPerDay).rounded(.up))
  }
}
