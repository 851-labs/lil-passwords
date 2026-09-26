# Shared config/helpers for scripts/release/*.sh. Source, don't execute:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Design: today the 851 Labs org has no Developer ID certificate or notary
# credentials, so every script here must work end to end with ad hoc signing
# and no notarization. Once DEVELOPER_ID_CERT_P12/DEVELOPER_ID_CERT_PASSWORD
# exist as secrets, signing_identity() starts returning a real Developer ID
# identity and everything downstream (notarization, stapling) switches on
# automatically — see has_developer_id_cert()/has_notary_credentials() below
# and docs/releasing.md.

set -uo pipefail

RELEASE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$RELEASE_ROOT"

PROJECT_FILE="LilPasswords.xcodeproj"
SCHEME="LilPasswords"
APP_NAME="lil passwords"

# Reuses the same derived data root as `make build` (see Makefile) so a
# release build benefits from the same module cache; Debug and Release
# products land in separate Build/Products/<config> subdirs either way.
DERIVED_DATA_DIR="$RELEASE_ROOT/build"
APP_PATH="$DERIVED_DATA_DIR/Build/Products/Release/$APP_NAME.app"

# Scratch space for release-only intermediates: imported keychain, downloaded
# Sparkle CLI tools, DMG staging, cached signing identity. Gitignored.
SCRATCH_DIR="$RELEASE_ROOT/build/release-scratch"
mkdir -p "$SCRATCH_DIR"

# Final artifacts CI/tophat actually publish.
DIST_DIR="$RELEASE_ROOT/dist"

VERSION="${RELEASE_VERSION:-}"
if [[ -z "$VERSION" ]]; then
  # `v1.2.3` tag -> `1.2.3`. Falls back to the xcconfig's MARKETING_VERSION
  # for local tophat runs off a branch with no tag.
  if [[ -n "${GITHUB_REF_NAME:-}" && "$GITHUB_REF_NAME" == v* ]]; then
    VERSION="${GITHUB_REF_NAME#v}"
  else
    VERSION="$(sed -n 's/^MARKETING_VERSION = \(.*\)$/\1/p' Config/Base.xcconfig | tr -d '[:space:]')"
  fi
fi
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"

DMG_NAME="LilPasswords-${VERSION}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

GITHUB_REPO="851-labs/lil-passwords"

# lil passwords ships under Alexandru Turcanu's personal Apple Developer team
# until the 851 Labs org has its own (851-2400, PR #16 — see the signing
# comment in Config/Base.xcconfig). Defaulting it here means a real Developer
# ID release doesn't need an org-issued APPLE_TEAM_ID secret configured
# separately; set APPLE_TEAM_ID explicitly to override once the org has its
# own team. This alone never turns on Developer ID signing — that still
# requires the actual certificate, see has_developer_id_cert() below.
APPLE_TEAM_ID="${APPLE_TEAM_ID:-WH4QW9ND3J}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
  exit 1
}

# Developer ID signing turns on once the certificate exists. APPLE_TEAM_ID
# always has a value (defaulted above), so it doesn't gate this — only the
# actual cert and its password do.
has_developer_id_cert() {
  [[ -n "${DEVELOPER_ID_CERT_P12:-}" && -n "${DEVELOPER_ID_CERT_PASSWORD:-}" ]]
}

# Notarization turns on once notary credentials exist too (either an Apple ID
# app-specific password, or an App Store Connect API key) *and* we actually
# have a Developer ID identity to sign with — Apple rejects ad hoc-signed
# submissions outright.
has_notary_credentials() {
  has_developer_id_cert || return 1
  if [[ -n "${NOTARY_API_KEY_ID:-}" && -n "${NOTARY_API_ISSUER_ID:-}" && -n "${NOTARY_API_KEY_P8:-}" ]]; then
    return 0
  fi
  [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]
}

# Prints the codesign identity to use, importing the Developer ID cert into a
# scratch keychain on first call and caching the result for subsequent calls
# within the same release run (each scripts/release/*.sh runs as its own
# process, so this can't just be a variable).
signing_identity() {
  local cache="$SCRATCH_DIR/.signing-identity"
  if [[ -f "$cache" ]]; then
    cat "$cache"
    return 0
  fi

  local identity
  if has_developer_id_cert; then
    identity="$("$RELEASE_ROOT/scripts/release/import-certificate.sh")"
  else
    identity="-"
  fi
  printf '%s' "$identity" >"$cache"
  printf '%s' "$identity"
}
