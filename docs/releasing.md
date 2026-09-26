# Releasing

Related: [851-2436](https://linear.app/851/issue/851-2436) (signing/notarization/DMG),
[851-2437](https://linear.app/851/issue/851-2437) (Sparkle appcast).

## TL;DR

Push a `v*` tag and `.github/workflows/release.yml` does the rest: build,
sign, package a DMG, notarize + staple it, generate `appcast.xml`, and upload
both to a GitHub Release at that tag.

```
git tag v0.1.0
git push origin v0.1.0
```

**Today there's no Developer ID Application certificate or notarization
credentials**, so releases build with ad hoc signing and no notarization.
(lil passwords ships under Alexandru Turcanu's personal Apple Developer team,
`WH4QW9ND3J` — see 851-2400/PR #16 and the signing comment in
`Config/Base.xcconfig` — but that's only wired up for local Xcode dev
signing; it doesn't by itself unlock Developer ID release signing, which
still needs the certificate below.) Nothing about the workflow needs to
change once that certificate exists — see [Turning on Developer ID signing](#turning-on-developer-id-signing-and-notarization)
below.

## Pipeline

`scripts/release/release.sh` runs each stage in order; every stage is a
standalone script you can also run on its own once earlier stages have run:

1. `xcodegen generate` — regenerate `LilPasswords.xcodeproj` from `project.yml`.
2. `build.sh` — `xcodebuild build` (Release configuration) of the app, the
   agent, and the CLI. Always builds with the project's default ad hoc
   identity; signing happens as its own step next.
3. `sign.sh` — signs inside out with each target's entitlements: Sparkle's
   bundled helper tools first (`Autoupdate`, `Updater.app`, its two XPC
   services), then the embedded `LilPasswordsAgent` and `lilpass`
   (`Contents/Helpers`), then `lil passwords.app` itself last, since its seal
   has to cover everything already signed inside it. Uses whichever identity
   `scripts/release/lib.sh`'s `signing_identity()` resolves — ad hoc today, a
   real Developer ID identity once one exists. Hardened runtime
   (`--options runtime`) is added only with a real Developer ID identity: it
   turns on dyld library validation, which requires everything a
   hardened-runtime process loads to share its Team ID, and ad hoc signatures
   have no Team ID for independently-signed objects (like this app binary and
   the Sparkle.framework dylib) to share — so an ad hoc build with hardened
   runtime forced on fails at launch (`Library not loaded: ... different Team
   IDs`) even though it looks perfectly valid to
   `codesign --verify --deep --strict`. Developer ID builds sign everything
   with one matching Team ID, so hardened runtime (required for notarization)
   just works.
4. `make-dmg.sh` — packages the signed app into `dist/LilPasswords-<version>.dmg`
   with the usual `.app` + `Applications` symlink layout via `hdiutil`, signs
   the DMG itself, then notarizes + staples it (`notarize.sh`) if
   credentials exist.
5. `generate-appcast.sh` — produces `dist/appcast.xml` from the DMG using
   Sparkle's `generate_appcast` tool, if `SPARKLE_ED_PRIVATE_KEY` exists.

Every stage that needs a secret that doesn't exist yet **warns and no-ops
instead of failing** — see [What happens with no secrets configured at all](#what-happens-with-no-secrets-configured-at-all).

The workflow then publishes (creates if missing) a GitHub Release at the
pushed tag and uploads `dist/*.dmg` and `dist/appcast.xml` (if generated) as
release assets, then bumps the Homebrew cask — see
[Homebrew cask](#homebrew-cask) below.

## Homebrew cask

851-2438: `brew install --cask 851-labs/tap/lil-passwords` installs from
`Casks/lil-passwords.rb` in [851-labs/homebrew-tap](https://github.com/851-labs/homebrew-tap),
a separate repo shared with 851 Labs' other tools. After the GitHub Release
is published, the release workflow's "Bump Homebrew cask" step clones that
tap, rewrites the cask's `version` and `sha256` to match the just-published
DMG, and opens a PR against it (`bump-lil-passwords-<version>` →
`homebrew-tap`'s `main`) — it deliberately doesn't push straight to `main`
or merge that PR itself.

This step needs a `HOMEBREW_TAP_TOKEN` secret: a token with write access to
851-labs/homebrew-tap (a fine-grained PAT scoped to that repo with Contents
and Pull requests write, or a classic PAT with `repo`) — the job's own
`GITHUB_TOKEN` only has access to this repo, not the tap. Like every other
secret in this pipeline, it's optional and the step **warns and no-ops
instead of failing** if it's unset, logging a workflow warning annotation
and leaving the tap's cask untouched.

The cask itself (`app`, `binary` for the `lilpass` CLI link, `zap`, Sparkle
`auto_updates`, etc.) is documented in its own comments in
`Casks/lil-passwords.rb`; it carries an ad hoc-signing caveat identical in
spirit to the DMG's own — see the note above — until 851-2436 lands.

## Secrets

All optional; the pipeline degrades gracefully without each one.

| Secret | Purpose |
| --- | --- |
| `DEVELOPER_ID_CERT_P12` | Base64-encoded `.p12` export of the "Developer ID Application" certificate. |
| `DEVELOPER_ID_CERT_PASSWORD` | Export password for the `.p12` above. |
| `APPLE_TEAM_ID` | Apple Developer Team ID. Optional — defaults to Alexandru Turcanu's team (`WH4QW9ND3J`, see `scripts/release/lib.sh`), who lil passwords ships under until the 851 Labs org has its own team. Only set this to override that default. |
| `NOTARY_APPLE_ID` + `NOTARY_PASSWORD` | An Apple ID (with an [app-specific password](https://support.apple.com/en-us/102654)) enrolled in the team, for `notarytool`. Alternative to the API key below. |
| `NOTARY_API_KEY_ID` + `NOTARY_API_ISSUER_ID` + `NOTARY_API_KEY_P8` | An App Store Connect API key instead of an Apple ID/password, for `notarytool`. |
| `SPARKLE_ED_PRIVATE_KEY` | The EdDSA private key Sparkle uses to sign appcast entries — see [Sparkle keys](#sparkle-keys). |
| `HOMEBREW_TAP_TOKEN` | A token with write access to 851-labs/homebrew-tap, used to open the cask-bump PR — see [Homebrew cask](#homebrew-cask). |

`DEVELOPER_ID_CERT_P12`/`DEVELOPER_ID_CERT_PASSWORD` gate Developer ID
signing (`lib.sh`'s `has_developer_id_cert`); `APPLE_TEAM_ID` isn't part of
that gate since it always has a value. Notarization additionally needs
either the Apple ID pair or the API key trio (`has_notary_credentials`), and
is skipped even with those set if there's no Developer ID identity to have
signed with — Apple rejects ad hoc submissions outright.

### Turning on Developer ID signing and notarization

Once a Developer ID Application certificate exists (whether issued under
Alexandru Turcanu's team or a future 851 Labs org team):

1. Export the "Developer ID Application" certificate + private key as a
   `.p12` from Keychain Access, then `base64 -i cert.p12 | pbcopy` into the
   `DEVELOPER_ID_CERT_P12` repo/org secret (and its export password into
   `DEVELOPER_ID_CERT_PASSWORD`).
2. Only set `APPLE_TEAM_ID` if the certificate belongs to a *different* team
   than `WH4QW9ND3J` (Apple Developer account → Membership, for the
   10-character ID) — it already defaults to Alexandru Turcanu's team, see
   the Secrets table above.
3. Either create an [app-specific password](https://support.apple.com/en-us/102654)
   for an Apple ID on the team (`NOTARY_APPLE_ID`/`NOTARY_PASSWORD`), or
   generate an App Store Connect API key with the Developer role
   (`NOTARY_API_KEY_ID`/`NOTARY_API_ISSUER_ID`/`NOTARY_API_KEY_P8`, the last
   being the raw contents of the downloaded `.p8` file).
4. Push a new tag. No workflow or script changes are needed — the next
   release signs with the real identity, notarizes, and staples
   automatically.

### Sparkle keys

Sparkle's `generate_keys` tool (bundled in the same
`Sparkle-for-Swift-Package-Manager.zip` release asset as `generate_appcast`;
download it from the [Sparkle releases page](https://github.com/sparkle-project/Sparkle/releases)
matching the version pinned in `Package.resolved`) creates an EdDSA keypair
and stores the private half in the local login Keychain:

```
./bin/generate_keys
```

Export the private key for CI and set it as the `SPARKLE_ED_PRIVATE_KEY`
secret:

```
./bin/generate_keys -x /tmp/sparkle_private_key
pbcopy < /tmp/sparkle_private_key
rm /tmp/sparkle_private_key
```

Print the public key and put it in `Config/Base.xcconfig` as
`SPARKLE_PUBLIC_ED_KEY` (it's baked into `Info.plist`'s `SUPublicEDKey` at
build time — see `project.yml`):

```
./bin/generate_keys -p
```

Until this is done, `SPARKLE_PUBLIC_ED_KEY` is an empty placeholder and
`App/Sources/Updates/UpdaterController.swift` treats that as "no updater
configured": it doesn't start Sparkle, and "Check for Updates…" no-ops.
This is deliberate — Sparkle treats an *empty* `SUPublicEDKey` as present but
malformed, not absent, which otherwise pops an "update checker failed to
start" alert on every launch.

## What happens with no secrets configured at all

This is the state of the repo today, and `scripts/release/release.sh` is
expected to run start to finish in this state:

- `build.sh`, `sign.sh` — build and sign the app, agent, CLI, and Sparkle's
  helper tools with the ad hoc identity (`-`) already set as the project
  default in `Config/Base.xcconfig`. No hardened runtime in this mode (see the
  pipeline step above) — the app launches and runs locally like any other ad
  hoc build.
- `make-dmg.sh` — packages and ad hoc-signs the DMG. `notarize.sh` warns and
  returns successfully without submitting anything.
- `generate-appcast.sh` — warns and exits successfully without writing
  `dist/appcast.xml`.
- The workflow still creates the GitHub Release and uploads the DMG; it logs
  a workflow warning annotation that no appcast was generated.

The resulting DMG installs and runs fine locally (macOS will show the usual
unidentified-developer Gatekeeper prompt on first launch, dismissible via
right-click → Open), but will fail Gatekeeper's stricter checks on another
Mac and isn't discoverable by Sparkle. That's the expected, documented state
until 851-2436's Developer ID secrets exist — see that ticket for status.

## Local tophat

Run the whole pipeline locally exactly as CI does:

```
scripts/release/release.sh
```

Or a single stage at a time, e.g. after editing `sign.sh`:

```
scripts/release/build.sh
scripts/release/sign.sh
```

Useful verification commands against the results:

```
# Inspect the built app's signature
codesign -dv --verbose=4 "build/Build/Products/Release/lil passwords.app"
codesign --verify --deep --strict --verbose=2 "build/Build/Products/Release/lil passwords.app"

# Mount the DMG and look at what shipped inside it
hdiutil attach dist/LilPasswords-*.dmg
ls "/Volumes/lil passwords"
hdiutil detach "/Volumes/lil passwords"
```

`generate-appcast.sh` needs `SPARKLE_ED_PRIVATE_KEY` set in your shell to do
anything (see [Sparkle keys](#sparkle-keys) for a throwaway local keypair via
`generate_keys` if you just want to exercise the script).

## Versioning

The DMG and `Info.plist`'s `CFBundleShortVersionString` both come from the
pushed tag (`vX.Y.Z` → `X.Y.Z`); `CFBundleVersion` comes from the GitHub
Actions run number. Outside CI (no `GITHUB_REF_NAME`/`GITHUB_RUN_NUMBER`),
`scripts/release/lib.sh` falls back to `Config/Base.xcconfig`'s
`MARKETING_VERSION` and build number `1`, so local tophat runs work without a
tag. Override either with `RELEASE_VERSION=1.2.3 scripts/release/release.sh`.
