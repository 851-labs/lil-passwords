import AppKit

/// A single label/value row meant to sit inside a ``CardView``: the label on the left (or, in
/// `stacked` rows, above), a caller-supplied content view opposite it, and an optional small
/// trailing accessory — Apple Passwords' style for every row in the New Password sheet's card
/// (851-2416): "User Name", "Password", "Website" (inline: label left, value right-aligned), and
/// "Notes" (stacked: label above a multi-line value, both left-aligned).
///
/// Deliberately styling-agnostic about `value` and `accessory` — this only lays them out; callers
/// own the value view's font/color/editability (a plain bezel-less `NSTextField` for most rows, a
/// composite masked/reveal view for Password). That keeps this reusable by 851-2463's detail-pane
/// layout work, whose rows want the same left/right shape but different value content (read-only
/// labels rather than editable fields).
@MainActor
final class KeyValueRow: NSView {
  let labelField = NSTextField(labelWithString: "")

  /// - Parameters:
  ///   - label: The row's label — "User Name", "Password", "Website", "Notes", etc.
  ///   - value: The row's content view. Typically a single bezel-less `NSTextField`, right-aligned
  ///     opposite the label in an inline row; can be any view, e.g. the New Password sheet's
  ///     masked/reveal password field, or a multi-line notes editor in a `stacked` row.
  ///   - accessory: An optional small trailing control shown to the right of `value` in an inline
  ///     row (e.g. a regenerate button). Ignored when `stacked` is true.
  ///   - stacked: When true, lays the row out with `label` above `value`, spanning the row's full
  ///     width and left-aligned, rather than side by side — for multi-line rows like Notes.
  init(label: String, value: NSView, accessory: NSView? = nil, stacked: Bool = false) {
    super.init(frame: .zero)
    configureSubviews(label: label, value: value, accessory: accessory, stacked: stacked)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func configureSubviews(label: String, value: NSView, accessory: NSView?, stacked: Bool) {
    translatesAutoresizingMaskIntoConstraints = false

    labelField.stringValue = label
    labelField.font = .systemFont(ofSize: 13)
    labelField.translatesAutoresizingMaskIntoConstraints = false

    value.translatesAutoresizingMaskIntoConstraints = false

    if stacked {
      configureStacked(value: value)
    } else {
      configureInline(value: value, accessory: accessory)
    }
  }

  private func configureStacked(value: NSView) {
    labelField.setContentHuggingPriority(.required, for: .vertical)

    let stack = NSStackView(views: [labelField, value])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false

    addSubview(stack)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
    ])
  }

  private func configureInline(value: NSView, accessory: NSView?) {
    labelField.setContentHuggingPriority(.required, for: .horizontal)

    addSubview(labelField)
    addSubview(value)

    let trailingAnchorConstraint: NSLayoutConstraint
    if let accessory {
      accessory.translatesAutoresizingMaskIntoConstraints = false
      addSubview(accessory)
      NSLayoutConstraint.activate([
        accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
      trailingAnchorConstraint = value.trailingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: -6)
    } else {
      trailingAnchorConstraint = value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
    }

    NSLayoutConstraint.activate([
      // Exactly 40, not just a floor: `label`/`value` only pin to `centerYAnchor` below (matching
      // Apple's vertically-centered label/value baseline), which leaves this view with no
      // intrinsic content size of its own. A `greaterThanOrEqualToConstant` floor alone is
      // ambiguous — `NSStackView` has nothing telling it *how much* taller than the floor to make
      // an arranged subview, so it was dumping the sheet's entire leftover vertical slack into
      // whichever row solved first, rather than spreading rows evenly at their natural height.
      heightAnchor.constraint(equalToConstant: 40),

      labelField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      labelField.centerYAnchor.constraint(equalTo: centerYAnchor),

      // An *equality* to `labelField`'s trailing edge, not just a `>=` floor: `value` is often an
      // empty, placeholder-only `NSTextField` (User Name/Website start blank), and an empty
      // editable field's intrinsic width is ambiguous — there's no real text to measure. A `>=`
      // floor leaves that ambiguity for Auto Layout to resolve on its own, which in practice
      // picked wildly inconsistent widths across structurally-identical rows (one row's value
      // collapsed to ~4pt while its sibling filled ~335pt). Filling the whole gap removes the
      // ambiguity outright — `value.alignment = .right` (set by callers) still keeps the visible
      // text flush against the trailing edge either way.
      value.leadingAnchor.constraint(equalTo: labelField.trailingAnchor, constant: 8),
      value.centerYAnchor.constraint(equalTo: centerYAnchor),
      trailingAnchorConstraint,
    ])
  }
}
