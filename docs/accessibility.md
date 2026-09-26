# Accessibility checklist (851-2426)

A short checklist for VoiceOver, keyboard, and display-accommodation support — run through this
before shipping any new screen or control, not just once for this ticket.

## VoiceOver: icon-only controls

- [ ] Every icon-only `NSButton`/`NSImageView` sets **both** `NSImage(accessibilityDescription:)`
      **and** the control's own `setAccessibilityLabel(...)`. Relying on the image's description
      alone is not reliably surfaced by VoiceOver as the control's label — this was a real,
      app-wide gap found and fixed in 851-2426 (`MainToolbarController`, `DetailValueRowView`,
      `PasswordEditRowView`, `WebsiteRowView`, `EditableListRowView`, `VerificationCodeRowView`,
      `AddVerificationCodeSheetController`, `CodesViewController`, `NewPasswordSheetController`,
      `MenuBarItemDetailViewController`).
- [ ] If a button's icon/meaning changes with state (e.g. reveal ↔ hide), the label updates with
      it. `PasswordEditRowView`'s reveal button used to always say "Reveal Password" even after
      being revealed — fixed to track state.
- [ ] A plain `NSView` used as a click target (no real `NSControl`) exposes itself explicitly via
      `setAccessibilityElement(true)` + `setAccessibilityRole(.button)` +
      `setAccessibilityLabel(...)` — see `MenuBarCopyableRowView`. Without this, VoiceOver only
      reads its subviews as inert text and never learns the row is actionable.
- [ ] A genuinely decorative icon (row already has its own accessible label, or the icon is purely
      illustrative next to explanatory text) keeps `accessibilityDescription: nil` rather than
      being announced twice — see `SidebarIconFactory`, `EmptyStateView`, the Touch ID badge in
      `LockScreenViewController`.

## VoiceOver: row descriptions

- [ ] Every list-style row (`NSTableCellView`/custom row view) calls `setAccessibilityElement(true)`
      and `setAccessibilityLabel(...)` with a single, meaningful sentence — e.g. "Amazon,
      jordan@…, has verification code" — instead of letting VoiceOver read the icon, title, and
      subtitle as three separate elements. Done for `ItemRowCellView` (main list),
      `SidebarRowView` (sidebar), `CodeRowCellView` (Codes), `DeletedItemRowCellView` (Deleted),
      `SecurityFindingRowCellView` (Security).

## Keyboard navigation

- [ ] Tab/Shift-Tab moves through the sidebar, item list, and detail pane in a sensible order.
      This app doesn't customize `nextKeyView`/`autorecalculatesKeyViewLoop` anywhere — it relies
      on AppKit's automatic key view loop, which is built from view-hierarchy order for standard
      `NSSplitViewController` + `NSOutlineView`/`NSTableView` panes. If a new column or floating
      panel is added, sanity-check Tab order rather than assuming it's automatically correct.
- [ ] Arrow keys move selection up/down within the sidebar and item list — free from
      `NSOutlineView`/`NSTableView`, not something this app implements itself.
- [ ] Return opens the selected list row for editing in the detail pane
      (`ItemTableView.insertNewline(_:)` → `ItemListViewController` →
      `ItemListViewControllerDelegate.itemListViewControllerDidRequestEdit(_:)` →
      `DetailViewController.beginEditingCurrentItem()`). A no-op with zero or multiple rows
      selected, or while already editing.
- [ ] ⌘C on a selected list row copies its password and shows the same "Password Copied"
      confirmation as the context menu's Copy Password item
      (`ItemTableView.copy(_:)` → `ItemListViewController.copyPasswordWithConfirmation()`). Note
      this is a plain `@objc func copy(_ sender: Any?)`, not `override` — `NSTableView`/
      `NSResponder` don't declare `copy(_:)` themselves, unlike `deleteBackward(_:)`/
      `deleteForward(_:)`, which genuinely are declared and must use `override`.
- [ ] Delete/Backspace on a selected list row deletes it (pre-existing, `onDeleteKey`).

## Increase Contrast / Reduce Transparency

- [ ] Prefer semantic `NSColor` (`.labelColor`, `.secondaryLabelColor`, `.separatorColor`,
      `.controlAccentColor`, `.windowBackgroundColor`, etc.) over fixed RGB values for any text,
      border, or background that carries meaning. These already repaint automatically when
      Increase Contrast is toggled in System Settings → Accessibility → Display — no extra code
      needed. Fixed RGB values in this codebase are limited to `MonogramIcon`'s decorative
      avatar-background palette, which is intentionally colorful (like Contacts' initials) and
      isn't a text/foreground contrast concern.
- [ ] Prefer a real `NSVisualEffectView` with a system `.material` (e.g. `.sidebar`) over a
      manually-drawn translucent layer for any chrome that should look like the rest of macOS.
      `NSVisualEffectView` already renders as an opaque solid instead of blurring when Reduce
      Transparency is on — see `SidebarViewController`, the only translucent surface in the app.
- [ ] A CALayer-backed background/border color set once from a dynamic `NSColor`'s `.cgColor`
      (rather than redrawn on every appearance change) can go stale on a live light/dark or
      contrast toggle. None of this app's current `.cgColor` usages are tied to a *value* that
      changes under Increase Contrast specifically (hover highlights, shadow color, a fixed card
      background) — but if a new one is added for something contrast-sensitive, override
      `viewDidChangeEffectiveAppearance()` to refresh it.

## How to test manually

- **VoiceOver**: ⌘F5 to toggle, then Control-Option-arrow keys to walk the app.
- **Accessibility Inspector**: Xcode → Open Developer Tool → Accessibility Inspector → point it at
  a running build; check every control has a non-empty label and a sensible role, and run its
  built-in audit.
- **Increase Contrast / Reduce Transparency**: System Settings → Accessibility → Display.
- **Full keyboard**: unplug the mouse; Tab/Shift-Tab, arrow keys, Return, ⌘C, Delete should cover
  everything above.
