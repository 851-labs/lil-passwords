#!/usr/bin/env bash
# 851-2476: asserts a signed AutoFill.appex embeds a provisioning profile and
# that every restricted entitlement it's signed with is allowed by that profile
# (AMFI's launch check, done ahead of time so a mismatch fails the release
# instead of the user's AutoFill). com.apple.security.* keys (App Sandbox and
# its temporary exceptions) aren't profile-gated and are skipped.
#
# Usage: verify-autofill-profile.sh [path/to/AutoFill.appex]
#   Defaults to the appex inside the Release app build.sh produces.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APPEX="${1:-$APP_PATH/Contents/PlugIns/AutoFill.appex}"
EMBEDDED="$APPEX/Contents/embedded.provisionprofile"
[[ -f "$EMBEDDED" ]] || die "$EMBEDDED not found"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
security cms -D -i "$EMBEDDED" >"$WORK/profile.plist" 2>/dev/null || die "$EMBEDDED isn't a valid provisioning profile"
/usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$WORK/profile.plist" >"$WORK/allowed.plist"
codesign -d --entitlements - --xml "$APPEX" >"$WORK/signed.plist" 2>/dev/null
[[ -s "$WORK/signed.plist" ]] || die "$APPEX has no signed entitlements"

# Top-level keys of a plist, one per line (PlistBuddy indents them by 4 spaces).
top_level_keys() { /usr/libexec/PlistBuddy -c "Print" "$1" | sed -n 's/^    \([^ ][^ ]*\) = .*/\1/p'; }
# A scalar prints as itself; an array prints one element per line.
values() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null | sed -e '/ {$/d' -e '/^}$/d' -e 's/^ *//'; }

for required in com.apple.application-identifier com.apple.developer.team-identifier; do
  top_level_keys "$WORK/signed.plist" | grep -qx "$required" || die "$APPEX isn't signed with $required — AMFI can't match it to its profile"
done

checked=0
while IFS= read -r key; do
  case "$key" in com.apple.security.*) continue ;; esac
  allowed="$(values "$WORK/allowed.plist" "$key")"
  [[ -n "$allowed" ]] || die "$APPEX is signed with $key, which its provisioning profile doesn't allow"
  while IFS= read -r value; do
    ok=false
    while IFS= read -r pattern; do
      # shellcheck disable=SC2053 # profile values may be globs (e.g. "TEAM.*").
      if [[ "$value" == $pattern ]]; then
        ok=true
        break
      fi
    done <<<"$allowed"
    $ok || die "$APPEX: signed $key value '$value' isn't allowed by its provisioning profile"
  done < <(values "$WORK/signed.plist" "$key")
  checked=$((checked + 1))
done < <(top_level_keys "$WORK/signed.plist")

log "AutoFill.appex embeds its provisioning profile; all $checked profile-gated entitlement(s) are allowed by it"
