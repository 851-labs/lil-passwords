#!/usr/bin/env bash
# Imports the Developer ID Application certificate (DEVELOPER_ID_CERT_P12,
# base64-encoded .p12; DEVELOPER_ID_CERT_PASSWORD, its export password) into a
# throwaway keychain and prints the resulting codesign identity's SHA-1 hash
# on stdout — and ONLY that (851-2474: lib.sh captures stdout as the identity,
# so every tool's output here goes to stderr). Only called via lib.sh's
# signing_identity() once has_developer_id_cert() is true — never invoke directly without those
# secrets set.
#
# Uses a dedicated scratch keychain rather than the login/System keychain so
# this is safe to run on a CI runner (no interactive keychain unlock needed)
# and repeatable on a dev machine without polluting the real login keychain.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

has_developer_id_cert || die "import-certificate.sh requires DEVELOPER_ID_CERT_P12 and DEVELOPER_ID_CERT_PASSWORD"

KEYCHAIN_PATH="$SIGNING_KEYCHAIN_PATH"
KEYCHAIN_PASSWORD="$(uuidgen)"
CERT_PATH="$SCRATCH_DIR/developer-id.p12"

trap 'rm -f "$CERT_PATH"' EXIT

# Always start from a fresh keychain: the random password below is not
# persisted, so a keychain left over from an earlier run can't be unlocked.
# stdout is reserved for the identity (captured via command substitution in
# lib.sh), so every tool's output is sent to stderr.
if [[ -f "$KEYCHAIN_PATH" ]]; then
  security delete-keychain "$KEYCHAIN_PATH" >&2 || rm -f "$KEYCHAIN_PATH"
fi

log "Creating scratch keychain for Developer ID signing"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >&2
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH" >&2
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >&2

base64 --decode <<<"$DEVELOPER_ID_CERT_P12" >"$CERT_PATH"
security import "$CERT_PATH" -k "$KEYCHAIN_PATH" -P "$DEVELOPER_ID_CERT_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security >&2
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >&2

# Put the scratch keychain on the user search list (codesign also gets an
# explicit --keychain, see lib.sh) so the identity and its chain resolve.
EXISTING_KEYCHAINS="$(security list-keychains -d user | tr -d '"')"
# shellcheck disable=SC2086
security list-keychains -d user -s "$KEYCHAIN_PATH" $EXISTING_KEYCHAINS >&2

# The SHA-1 hash is unambiguous even if several certs share a name.
IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Developer ID Application:.*/\1/p' | head -n1)"
[[ -n "$IDENTITY" ]] || die "No 'Developer ID Application' identity found after importing DEVELOPER_ID_CERT_P12"

printf '%s' "$IDENTITY"
