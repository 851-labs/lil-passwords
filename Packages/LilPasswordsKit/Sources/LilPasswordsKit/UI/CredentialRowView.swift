import AppKit

/// A single credential row in a list: monogram icon, title, and a secondary line (usually a
/// username) — the Apple Passwords item-row layout, with a 40pt icon and a hairline separator
/// inset to start at the text rather than under the icon.
///
/// 851-2441: moved here from the app target (`App/Sources/MainWindow/ItemRowView.swift`, where it
/// was named `ItemRowCellView`) and made `public` — under a new, more general name — so both the
/// app's own item list and the sandboxed `AutoFillExtension`'s `prepareCredentialList(for:)` list
/// (a separate bundle, with no access to `PasswordItem`'s full shape — only the narrow
/// `CredentialIdentity` the helper hands back over XPC) render identically without duplicating
/// this view. ``configure(title:subtitle:hidesSeparator:)`` is the primitive both callers can use;
/// ``configure(with:hidesSeparator:)`` is a `PasswordItem`-specific convenience kept for the app's
/// existing call sites, which never had to change.
///
/// 851-2459 (rebased onto this type after it moved here): ``configure(with:hidesSeparator:)`` can
/// fetch a real website icon via the injectable ``iconLoader``, cancelling any in-flight fetch on
/// reuse. See ``iconLoader``'s own doc comment for why that's a closure rather than a direct call.
public final class CredentialRowView: NSTableCellView {
  public static let reuseIdentifier = NSUserInterfaceItemIdentifier("ItemRow")

  private let iconView = NSImageView()
  private let titleField = NSTextField(labelWithString: "")
  private let subtitleField = NSTextField(labelWithString: "")
  private let separator = NSBox()

  /// Cancelled and replaced on every ``configure(with:hidesSeparator:)`` call, and cancelled again
  /// in ``prepareForReuse()``, so a slow icon fetch for a row this cell used to represent can never
  /// land after `NSTableView` has recycled the cell for a different item (851-2459). This lived on
  /// `ItemRowCellView` itself before this type moved to `LilPasswordsKit` in 851-2441; the move kept
  /// it here rather than in the app's call site because the cell — not the table view controller —
  /// is the thing `NSTableView` actually recycles.
  private var iconLoadTask: Task<Void, Never>?

  /// Injected by a caller that wants real website icons for its rows — currently only the app's own
  /// item list (`ItemListViewController`), which sets this to `WebsiteIconLoader.loadIcon`. Wired as
  /// a closure instead of a direct call because `WebsiteIconLoader` lives in the App target: it
  /// reads the App-target-only "Show website icons" setting and hits the network, neither of which
  /// the sandboxed AutoFill extension's credential picker should do. Left `nil` (the default), rows
  /// just keep showing ``MonogramIcon`` and never attempt a fetch — the case for every other caller
  /// of this view (`MenuBarListViewController`, `AddVerificationCodeSheetController`, and the
  /// AutoFill extension's own list, none of which are among the "4 places" 851-2459 calls out).
  ///
  /// - Note: `dimension` (851-2467, rebased onto this type after it moved here) is always
  ///   ``iconDimension`` for this view's own fixed 40pt icon, but is threaded through explicitly —
  ///   rather than assumed by the loader — so `WebsiteIconLoader.loadIcon` can hand the same
  ///   fetched icon to callers with different icon sizes (the detail pane, menu bar item detail,
  ///   and New Password sheet, none of which go through `CredentialRowView`) without this type's
  ///   own fixed size leaking into that shared entry point's contract.
  public typealias IconLoader = (
    _ host: String?, _ dimension: CGFloat, _ onIconLoaded: @escaping @MainActor (NSImage) -> Void
  ) -> Task<Void, Never>?
  public var iconLoader: IconLoader?

  /// The side length, in points, this view's icon is drawn at — fixed by its own layout
  /// constraints below, and passed to ``iconLoader`` so a fetched icon is clipped/tiled to match.
  private static let iconDimension: CGFloat = 40

  public static func dequeue(from tableView: NSTableView, owner: Any?) -> CredentialRowView {
    if let existing = tableView.makeView(withIdentifier: reuseIdentifier, owner: owner) as? CredentialRowView {
      return existing
    }
    return CredentialRowView()
  }

  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    identifier = Self.reuseIdentifier
    configureSubviews()
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func configureSubviews() {
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.imageScaling = .scaleProportionallyUpOrDown

    titleField.translatesAutoresizingMaskIntoConstraints = false
    titleField.font = .boldSystemFont(ofSize: 13)
    titleField.lineBreakMode = .byTruncatingTail

    subtitleField.translatesAutoresizingMaskIntoConstraints = false
    subtitleField.font = .systemFont(ofSize: 11)
    subtitleField.textColor = .secondaryLabelColor
    subtitleField.lineBreakMode = .byTruncatingTail

    separator.boxType = .separator
    separator.translatesAutoresizingMaskIntoConstraints = false

    addSubview(iconView)
    addSubview(titleField)
    addSubview(subtitleField)
    addSubview(separator)

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 40),
      iconView.heightAnchor.constraint(equalToConstant: 40),

      titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
      titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
      titleField.topAnchor.constraint(equalTo: topAnchor, constant: 9),

      subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
      subtitleField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
      subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),

      // Inset to start at the text, not under the icon, matching Apple Passwords.
      separator.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
      separator.trailingAnchor.constraint(equalTo: trailingAnchor),
      separator.bottomAnchor.constraint(equalTo: bottomAnchor),
      separator.heightAnchor.constraint(equalToConstant: 1),
    ])
  }

  /// The primitive both the app and the AutoFill extension configure a row through.
  ///
  /// - Parameters:
  ///   - title: The row's bold title line; also drives the monogram's letter/tint.
  ///   - subtitle: The secondary line (usually a username), or `nil` to hide it entirely.
  ///   - hidesSeparator: Whether this row's bottom hairline should be hidden — true when this row,
  ///     or the row immediately below it, is selected, so no hairline ever cuts through a rounded
  ///     selection highlight. Kept in sync after the initial `configure` call by
  ///     ``setSeparatorHidden(_:)``, since selection changes don't re-invoke `configure`.
  public func configure(title: String, subtitle: String?, hidesSeparator: Bool) {
    iconView.image = MonogramIcon.icon(for: title, dimension: Self.iconDimension)
    titleField.stringValue = title
    subtitleField.stringValue = subtitle ?? ""
    subtitleField.isHidden = subtitle == nil
    separator.isHidden = hidesSeparator

    // A meaningful VoiceOver description for the whole row (851-2426) — "Amazon, jordan@…" is the
    // exact shape the ticket calls out — rather than just the title a plain `NSTableCellView`
    // would otherwise expose via its subviews individually. `configure(with:hidesSeparator:)`
    // below extends this with "has verification code" for `PasswordItem`'s own extra context.
    setAccessibilityElement(true)
    setAccessibilityLabel(Self.accessibilityLabel(title: title, subtitle: subtitle, hasVerificationCode: false))
  }

  /// `PasswordItem`-specific convenience over ``configure(title:subtitle:hidesSeparator:)`` — the
  /// app's own item list has a full `PasswordItem`, unlike the AutoFill extension (see this type's
  /// own documentation), so this keeps its call sites unchanged from before this type moved here.
  public func configure(with item: PasswordItem, hidesSeparator: Bool) {
    iconLoadTask?.cancel()

    let subtitle = item.usernames.first(where: { !$0.isEmpty })
    configure(title: item.title, subtitle: subtitle, hidesSeparator: hidesSeparator)
    setAccessibilityLabel(
      Self.accessibilityLabel(title: item.title, subtitle: subtitle, hasVerificationCode: item.totpURI != nil))

    iconLoadTask = iconLoader?(item.websites.first?.host, Self.iconDimension) { [weak self] icon in
      self?.iconView.image = icon
    }
  }

  public override func prepareForReuse() {
    super.prepareForReuse()
    iconLoadTask?.cancel()
    iconLoadTask = nil
  }

  private static func accessibilityLabel(title: String, subtitle: String?, hasVerificationCode: Bool) -> String {
    var parts = [title]
    if let subtitle { parts.append(subtitle) }
    if hasVerificationCode { parts.append(String(localized: "has verification code")) }
    return parts.joined(separator: ", ")
  }

  public func setSeparatorHidden(_ hidden: Bool) {
    separator.isHidden = hidden
  }
}
