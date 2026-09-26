#!/usr/bin/env bash
# Imports the Developer ID Application certificate (DEVELOPER_ID_CERT_P12,
# base64-encoded .p12; DEVELOPER_ID_CERT_PASSWORD, its export password) into a
# throwaway keychain and prints the resulting codesign identity name on
# stdout. Only called via lib.sh's signing_identity() once
# has_developer_id_cert() is true — never invoke directly without those
# secrets set.
#
# Uses a dedicated scratch keychain rather than the login/System keychain so
# this is safe to run on a CI runner (no interactive keychain unlock needed)
# and repeatable on a dev machine without polluting the real login keychain.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

has_developer_id_cert || die "import-certificate.sh requires DEVELOPER_ID_CERT_P12, DEVELOPER_ID_CERT_PASSWORD, and APPLE_TEAM_ID"

KEYCHAIN_PATH="$SCRATCH_DIR/release-signing.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
CERT_PATH="$SCRATCH_DIR/developer-id.p12"

trap 'rm -f "$CERT_PATH"' EXIT

if [[ ! -f "$KEYCHAIN_PATH" ]]; then
  log "Creating scratch keychain for Developer ID signing"
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

  base64 --decode <<<"$DEVELOPER_ID_CERT_P12" >"$CERT_PATH"
  security import "$CERT_PATH" -k "$KEYCHAIN_PATH" -P "$DEVELOPER_ID_CERT_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null

  # Make codesign consider this keychain without requiring it to be the
  # user's default/login keychain.
  EXISTING_KEYCHAINS="$(security list-keychains -d user | tr -d '"')"
  security list-keychains -d user -s "$KEYCHAIN_PATH" $EXISTING_KEYCHAINS
fi

IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n1)"
[[ -n "$IDENTITY" ]] || die "No 'Developer ID Application' identity found after importing DEVELOPER_ID_CERT_P12"

printf '%s' "$IDENTITY"
