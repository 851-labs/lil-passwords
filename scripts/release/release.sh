#!/usr/bin/env bash
# Full release pipeline: generate the Xcode project, build, sign (ad hoc
# today; Developer ID automatically once its secrets exist — see lib.sh),
# package a DMG, notarize + staple it (once notary secrets exist), and
# generate appcast.xml (once SPARKLE_ED_PRIVATE_KEY exists). Used by
# .github/workflows/release.yml and for local tophat runs.
#
# Every step here is safe to run today with none of those secrets set — see
# docs/releasing.md and 851-2436/851-2437.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"

log "lil passwords release: version $VERSION (build $BUILD_NUMBER)"
# Each run imports the Developer ID cert fresh, and removes the scratch
# keychain (private key included) from disk and the search list on exit.
cleanup_signing() {
  rm -f "$SCRATCH_DIR/.signing-identity" "$SCRATCH_DIR/notary-api-key.p8"
  if [[ -f "$SIGNING_KEYCHAIN_PATH" ]]; then
    security delete-keychain "$SIGNING_KEYCHAIN_PATH" 2>/dev/null || rm -f "$SIGNING_KEYCHAIN_PATH"
  fi
}
cleanup_signing
trap cleanup_signing EXIT

xcodegen generate
"$DIR/build.sh"
"$DIR/sign.sh"
"$DIR/make-dmg.sh"
"$DIR/generate-appcast.sh"

log "Release artifacts:"
log "  $DMG_PATH"
# `if`, not `[[ ]] && log`: as the script's last command, a false test made
# the whole release exit 1 whenever no appcast was generated (851-2474).
if [[ -f "$DIST_DIR/appcast.xml" ]]; then
  log "  $DIST_DIR/appcast.xml"
fi
