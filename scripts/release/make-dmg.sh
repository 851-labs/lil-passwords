#!/usr/bin/env bash
# Packages the signed app into a DMG (with the usual drag-to-/Applications
# layout), signs the DMG itself, then notarizes + staples it if credentials
# exist. Run after sign.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/notarize.sh"

[[ -d "$APP_PATH" ]] || die "$APP_PATH not found — run build.sh and sign.sh first"

# Notarize + staple the app first so the copy inside the DMG carries its own
# ticket (works offline after the DMG is dragged out). No-ops without creds.
notarize_and_staple "$APP_PATH"

STAGING_DIR="$SCRATCH_DIR/dmg-staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR" "$DIST_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
log "Creating $DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"

IDENTITY="$(signing_identity)"
if [[ "$IDENTITY" == "-" ]]; then
  warn "Signing DMG ad hoc ('-')."
  codesign --force --sign - "$DMG_PATH"
else
  log "Signing DMG with $IDENTITY"
  codesign --force --sign "$IDENTITY" --timestamp --keychain "$SIGNING_KEYCHAIN_PATH" "$DMG_PATH"
fi

notarize_and_staple "$DMG_PATH"

log "DMG ready: $DMG_PATH"
