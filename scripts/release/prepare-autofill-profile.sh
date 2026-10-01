#!/usr/bin/env bash
# 851-2476: decodes AUTOFILL_PROVISIONING_PROFILE (base64 Developer ID
# provisioning profile for com.851labs.lilpasswords.autofill), checks it's
# actually usable for this signing run, embeds it in the appex as
# Contents/embedded.provisionprofile, and prints the path of the entitlements
# plist the appex should be signed with. Called by sign.sh; see the comment on
# its step 3 for why.
#
# Usage: prepare-autofill-profile.sh <AutoFill.appex> <base.entitlements> <identity SHA-1>
#
# Never prints the profile or its certificates: only pass/fail and the
# profile's name, team, app ID, and expiry, which are all non-secret.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APPEX="$1"
BASE_ENTITLEMENTS="$2"
IDENTITY="$3"

[[ -n "${AUTOFILL_PROVISIONING_PROFILE:-}" ]] || die "AUTOFILL_PROVISIONING_PROFILE is not set"
[[ -d "$APPEX" ]] || die "$APPEX not found"

PROFILE="$SCRATCH_DIR/autofill.provisionprofile"
PROFILE_PLIST="$SCRATCH_DIR/autofill-profile.plist"
SIGNED_ENTITLEMENTS="$SCRATCH_DIR/AutoFillExtension.signed.entitlements"

base64 --decode <<<"$AUTOFILL_PROVISIONING_PROFILE" >"$PROFILE" 2>/dev/null \
  || die "AUTOFILL_PROVISIONING_PROFILE is not valid base64"
security cms -D -i "$PROFILE" >"$PROFILE_PLIST" 2>/dev/null \
  || die "AUTOFILL_PROVISIONING_PROFILE doesn't decode to a signed provisioning profile (security cms -D failed)"

profile_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$PROFILE_PLIST" 2>/dev/null || true; }

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APPEX/Contents/Info.plist")"
EXPECTED_APP_ID="$APPLE_TEAM_ID.$BUNDLE_ID"

NAME="$(profile_value Name)"
TEAM="$(profile_value TeamIdentifier:0)"
APP_ID="$(profile_value Entitlements:com.apple.application-identifier)"
AUTOFILL="$(profile_value Entitlements:com.apple.developer.authentication-services.autofill-credential-provider)"
ALL_DEVICES="$(profile_value ProvisionsAllDevices)"
EXPIRES="$(plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log "AutoFill provisioning profile: '$NAME' (team $TEAM, app ID $APP_ID, expires $EXPIRES)"
[[ "$TEAM" == "$APPLE_TEAM_ID" ]] || die "AutoFill profile is for team '$TEAM', but this release signs as team $APPLE_TEAM_ID"
# shellcheck disable=SC2053 # $APP_ID is intentionally a glob (wildcard profiles are "TEAM.*").
[[ "$EXPECTED_APP_ID" == $APP_ID ]] || die "AutoFill profile's application-identifier '$APP_ID' doesn't cover $EXPECTED_APP_ID"
[[ "$AUTOFILL" == "true" ]] || die "AutoFill profile doesn't grant com.apple.developer.authentication-services.autofill-credential-provider"
[[ "$ALL_DEVICES" == "true" ]] || die "AutoFill profile isn't a Developer ID profile (ProvisionsAllDevices is not true) — a development profile only runs on its listed Macs"
[[ -n "$EXPIRES" && "$EXPIRES" > "$NOW" ]] || die "AutoFill profile expired ($EXPIRES) — regenerate it and update the AUTOFILL_PROVISIONING_PROFILE secret"

# The profile only authorizes the certificates it lists: signing with any other
# Developer ID cert (e.g. after a renewal) makes AMFI reject it at launch even
# though codesign and notarization are happy.
cert_matches=false
i=0
while cert="$(plutil -extract "DeveloperCertificates.$i" raw -o - "$PROFILE_PLIST" 2>/dev/null)"; do
  sha1="$(base64 --decode <<<"$cert" | openssl x509 -inform DER -noout -fingerprint -sha1 2>/dev/null | sed 's/^.*=//; s/://g')"
  if [[ "$sha1" == "$IDENTITY" ]]; then
    cert_matches=true
    break
  fi
  i=$((i + 1))
done
$cert_matches || die "AutoFill profile doesn't list the Developer ID certificate this release signs with ($i certificate(s) checked) — regenerate the profile against the current certificate"

cp "$PROFILE" "$APPEX/Contents/embedded.provisionprofile"
log "Embedded AutoFill provisioning profile at ${APPEX#"$APP_PATH"/}/Contents/embedded.provisionprofile"

# Base entitlements + the two identifiers a provisioned macOS extension needs in
# its own signature to be matched against the profile.
cp "$BASE_ENTITLEMENTS" "$SIGNED_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $EXPECTED_APP_ID" "$SIGNED_ENTITLEMENTS" >/dev/null
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $APPLE_TEAM_ID" "$SIGNED_ENTITLEMENTS" >/dev/null

printf '%s' "$SIGNED_ENTITLEMENTS"
