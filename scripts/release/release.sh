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
xcodegen generate
"$DIR/build.sh"
"$DIR/sign.sh"
"$DIR/make-dmg.sh"
"$DIR/generate-appcast.sh"

log "Release artifacts:"
log "  $DMG_PATH"
[[ -f "$DIST_DIR/appcast.xml" ]] && log "  $DIST_DIR/appcast.xml"
