#!/usr/bin/env bash
# 851-2475: assert the *built* AutoFill.appex still declares its credential
# provider capabilities. XcodeGen regenerates AutoFillExtension/Support/Info.plist
# from project.yml on every `xcodegen generate`, and once silently dropped
# NSExtensionAttributes — the appex built and notarized fine, but macOS would
# never offer it for passwords or passkeys. This catches that regression in the
# shipped bundle itself, not just in the source plist.
#
# Usage: verify-autofill-plist.sh [path/to/lil passwords.app]
#   Defaults to the Release app build.sh produces ($APP_PATH in lib.sh).
#   CI runs it against the Debug app `make build` produces.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TARGET_APP="${1:-$APP_PATH}"
PLIST="$TARGET_APP/Contents/PlugIns/AutoFill.appex/Contents/Info.plist"
[[ -f "$PLIST" ]] || die "$PLIST not found — was AutoFillExtension built and embedded?"

CAPS=":NSExtension:NSExtensionAttributes:ASCredentialProviderExtensionCapabilities"
for key in ProvidesPasswords ProvidesPasskeys; do
  value="$(/usr/libexec/PlistBuddy -c "Print $CAPS:$key" "$PLIST" 2>/dev/null || true)"
  [[ "$value" == "true" ]] || die "$PLIST: $CAPS:$key is '${value:-<missing>}', expected true — see project.yml's AutoFillExtension info.properties (851-2475)"
done

point="$(/usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionPointIdentifier" "$PLIST" 2>/dev/null || true)"
[[ "$point" == "com.apple.authentication-services-credential-provider-ui" ]] \
  || die "$PLIST: unexpected NSExtensionPointIdentifier '${point:-<missing>}'"

log "AutoFill.appex Info.plist declares ProvidesPasswords and ProvidesPasskeys"
