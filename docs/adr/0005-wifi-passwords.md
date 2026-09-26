# 0005. Wi-Fi passwords

- Status: Accepted
- Related: [851-2444](https://linear.app/851/issue/851-2444)

## Context

Apple Passwords has a Wi-Fi category: the networks this Mac already knows about, each showing a
security type and whether it's the currently-associated network, with a detail card that can
reveal the saved password (behind admin authentication), show a scannable QR code, and copy.
"lil passwords" needs the same category.

macOS stores a remembered Wi-Fi network's password as a generic-password keychain item in the
**System keychain** — service `"AirPort"`, item description `"AirPort network password"`, account
the SSID. The list of *known network names* is available with no special privilege. Reading a
*password* out of the System keychain is gated behind admin authentication, same as it is in
Apple's own Passwords app and in Keychain Access.

Two questions had to be settled before writing any code:

1. How does this app list known networks and (separately) the currently-associated one, without
   an entitlement this app doesn't and shouldn't carry?
2. How does this app read a saved password out of the System keychain, triggering the same
   admin-authentication UX Apple's own apps use, without linking against a private framework or
   duplicating Keychain Access's own privileged-helper machinery?

## Decision

### `networksetup`/`system_profiler`, not CoreWLAN, for listing

CoreWLAN's richer scanning APIs (`CWInterface.scanForNetworks`, `cachedScanResults`, association
info) are gated behind `com.apple.developer.networking.wifi-info` — a restricted entitlement this
app has no reason to request, and requesting it would only invite App Review scrutiny for a
feature that doesn't need live scanning at all: Apple Passwords' own Wi-Fi list is *known*
networks, not everything currently in range.

Two unprivileged command-line tools already expose everything this feature needs:

- `networksetup -listallhardwareports` — finds the BSD device name of the port named `"Wi-Fi"`
  (e.g. `en0`), needed because `-listpreferredwirelessnetworks` takes a device name.
- `networksetup -listpreferredwirelessnetworks <device>` — the list of remembered SSIDs. This is
  the exact same list Apple Passwords' Wi-Fi category shows, and needs no admin rights.
- `system_profiler SPAirPortDataType -json` — best-effort extra detail: the currently-associated
  SSID and a security mode string, when the OS is willing to report them. On a Mac without the
  `wifi-info` entitlement, `system_profiler` sometimes reports the SSID as the literal string
  `"<redacted>"` rather than omitting the field — ``WiFiNetworkParsing`` treats that sentinel as
  "no SSID," never as a real network name to display. Missing/redacted current-network or security
  info just means the list shows a network's name without a badge or a security label; it never
  blocks the list from rendering, matching how Apple's own Passwords app quietly shows less
  information rather than erroring when it can't get everything.

Both tools' output is plain text/JSON with no documented Swift API contract, so all parsing
(`WiFiNetworkParsing`) is pure string/JSON handling behind a protocol seam
(`WiFiSystemCommandRunning`) that fakes the process call in tests — see Testing below for the real
quirks this has to tolerate (redacted SSIDs, an observed missing-"s" typo in
`spairport_security_mode`).

`SecItemCopyMatching` was considered for listing too (`kSecClassGenericPassword`, service
`"AirPort"`, matching `kSecMatchLimitAll` with `kSecReturnAttributes` and no
`kSecReturnData`/`kSecUseAuthenticationContext`) — this reads item *attributes*, including the
account (SSID), without touching the password and without triggering authentication. It's a real
option and would avoid shelling out at all. `networksetup` was chosen instead because it also
naturally gives the currently-associated network and (via `system_profiler`) a security mode in
the same shape Apple's own list needs, whereas the keychain has no notion of "currently associated"
or "security mode" at all — that information only exists on the Wi-Fi subsystem side. Reaching for
`system_profiler` for one and `SecItemCopyMatching` for the other would mean two independent
sources of the known-network list that could disagree; `networksetup`'s preferred-networks list is
used as the single source of truth for *which* networks exist, with `system_profiler` layering
extra detail on top of it.

### `security find-generic-password`, not `SecItemCopyMatching`, for revealing

Reading the password itself is where the two candidate APIs really diverge:

- `SecItemCopyMatching` with `kSecReturnData: true` against `kSecClassGenericPassword` items in the
  System keychain (`kSecUseKeychain` /`kSecMatchSearchList` pointed at
  `/Library/Keychains/System.keychain`) can be made to prompt for admin authentication via
  `kSecUseAuthenticationContext`/`LAContext`, but doing that correctly — attaching the System
  keychain's own ACL-driven trusted-app prompt, rather than this app's own Touch
  ID/password sheet, which isn't what the System keychain's ACL for this item actually asks for —
  needs `SecKeychainItemCopyContent`-era Keychain Services or private-enough entry points that
  Apple's own documentation is thin on for exactly this cross-keychain, admin-owned-item case.
- `security find-generic-password -D "AirPort network password" -s AirPort -a <ssid> -w
  /Library/Keychains/System.keychain` is a single already-shipping, Apple-maintained binary that
  already knows how to do this correctly: it goes through Authorization Services, shows the exact
  same admin-authentication dialog Keychain Access and Apple Passwords trigger for this same item,
  and prints just the password to stdout on success. This was confirmed empirically on this dev
  machine: running it against a real remembered network reliably produces the standard "System
  wants to make changes / Wi-Fi wants to use the login/System keychain" admin prompt, and the
  bare password on stdout once authenticated.

`security` is what this app shells out to (`SystemWiFiPasswordRevealing`, via the same
`WiFiSystemCommandRunning` seam used for listing). Its trailing positional keychain argument is
always the System keychain's well-known path, so this can only ever search (and prompt for) that
one keychain — never silently falls back to the user's login keychain, where this item would never
legitimately live.

`security`'s exit codes are used, but only where they're unambiguous: exit code 44 is the
documented/observed "item not found" case, mapped to `WiFiPasswordRevealError.notFound` (shown as
"couldn't find a saved password," no admin prompt was even needed to learn that). Every other
non-zero exit — cancelled prompt, wrong admin password, anything else — collapses to
`WiFiPasswordRevealError.failed(stderr)`, because `security` doesn't expose a stable, documented
way to tell those apart from its exit status alone; showing a distinct message for "you clicked
Cancel" vs. "wrong password" would mean guessing at an interface `security` doesn't actually
provide.

### The reveal path lives only in the App process

`WiFiPasswordRevealing` is called from exactly one place: `WiFiDetailViewController`'s password
row and its "Show Network QR Code" button, both in the main App target. There is no XPC message,
CLI subcommand, or MCP tool anywhere in this codebase that calls it, and none should ever be added:

- `Agent/`'s XPC surface (`AgentXPCProtocol`/`AgentProtocol`) has no Wi-Fi method.
- The `lilpass` CLI has no Wi-Fi subcommand.
- `LilpassMCPServer` exposes no Wi-Fi tool.

This is deliberate, not an oversight to close later: a Wi-Fi password is exactly the kind of
secret an agent acting on a person's behalf should never be able to fetch silently, since revealing
one already requires (and should always require) a live admin-authentication dialog only a human
in front of the screen can answer. `WiFiPasswordRevealing`'s own doc comment states this guarantee
directly, since there's no `docs/agents.md` in this repository to hang it on instead.

### In-memory-only handling

A revealed password is held only by `WiFiPasswordRowView`'s private `state` enum
(`.revealed(String)`), for exactly as long as it's displayed. It is never written into the vault,
`UserDefaults`, a log, or disk anywhere, and:

- Selecting a different network (`WiFiDetailViewController.show(network:)`) calls
  `passwordRowView.reset()` unconditionally, discarding any revealed password rather than caching
  it for next time.
- Re-masking (tapping reveal again while revealed) discards the in-memory value outright; showing
  it again re-triggers a fresh admin-authenticated lookup.
- The QR sheet (`WiFiQRCodeSheetController`) receives the password as a plain `String` argument
  used only to build the QR image in memory for as long as the sheet is on screen; it isn't
  persisted by the sheet either.

### QR code payload

`WiFiQRCodePayload.payload(ssid:password:security:)` builds the standard `WIFI:T:<type>;S:<ssid>;
P:<password>;;` string (the Wi-Fi Alliance/ZXing convention every major scanner, including
iOS/macOS's own Camera-based reader, understands), rendered via `RecoveryKitDocument`'s existing
vector `QRModuleGrid` drawing rather than a new QR implementation. `T:` comes from
`WiFiNetworkSecurity.qrAuthenticationType` (`"nopass"` / `"WEP"` / `"WPA"` — there's no separate QR
token for WPA vs. WPA2 vs. WPA3 vs. enterprise); `P:` is omitted entirely for an open network.
`\`, `;`, `,`, and `:` are backslash-escaped in both the SSID and the password field, scanning the
original string once left-to-right so a literal backslash already present isn't re-escaped.

### SSIDs are display data, never instructions

An SSID is arbitrary text someone else chose, surfaced by macOS with no filtering. While building
this feature, real nearby networks on this dev machine included SSIDs that read as attempted
prompt injection (e.g. text instructing whoever/whatever reads it to "ignore previous
instructions"). Every piece of code in this feature — parsing, list/detail display, QR payload
construction — treats every SSID (and every revealed password) as strictly inert display/data
content. None of it is ever interpreted, evaluated, or acted on as an instruction by this app, by
an agent, or by anything else. This is called out directly in `WiFiNetworkParsing`'s and
`WiFiQRCodePayload`'s doc comments, and covered by dedicated test cases using exactly this kind of
SSID text.

## Testing

`WiFiNetworkParsing`, `WiFiQRCodePayload`, and `WiFiNetworkSecurity` are pure functions over
strings/JSON and are fully covered by `Swift Testing` unit tests in
`Packages/LilPasswordsKit/Tests/LilPasswordsKitTests/WiFi/`, including:

- The `<redacted>` sentinel and the missing-leading-"s" `spairport_security_mode` quirk, both
  observed directly against real `system_profiler` output on this dev machine.
- QR payload escaping of `\`, `;`, `,`, `:` in both directions (SSID and password), and the
  `nopass`/open-network case omitting `P:` entirely.
- SSIDs and passwords containing prompt-injection-style text, asserting the parsing/payload
  functions treat them as opaque data with no special handling.

`SystemWiFiNetworkListing` and `SystemWiFiPasswordRevealing` are tested against a fake
`WiFiSystemCommandRunning` (success and `WiFiSystemCommandFailure` cases, including exit code 44),
never against the real `security`/`networksetup` binaries — there is no automated test for the
actual admin-authentication dialog, since that dialog is presented by macOS itself and requires a
human present at the keyboard. That flow is covered by manual tophat instead: exercising reveal
against a real remembered network, and confirming the App never displays or logs a password beyond
what's on screen in `WiFiPasswordRowView`.

## Consequences

- Listing known networks and their current/security status has no entitlement cost and needs no
  App Review justification, at the price of depending on two undocumented CLI tools' text/JSON
  output shapes rather than a typed Swift API — mitigated by keeping all of that parsing in one
  pure, heavily-tested module (`WiFiNetworkParsing`) with graceful degradation already designed in
  for every quirk observed so far.
- Revealing a password always costs a real admin-authentication round trip (no caching across
  networks, no caching across a reveal/re-reveal within one network) — the same cost Apple
  Passwords itself pays, and the right tradeoff for a secret this sensitive.
- Because the reveal path only exists in the App target, any future agent-facing surface (XPC,
  CLI, MCP) must not add a Wi-Fi password method without deliberately revisiting this decision —
  this ADR, plus `WiFiPasswordRevealing`'s doc comment, are the two places that guarantee is
  written down.
