#!/usr/bin/env bash
# Release build of the app, agent, and CLI. Deliberately identity-agnostic:
# this always builds with the project's default ad hoc identity
# (Config/Base.xcconfig), and sign.sh re-signs everything inside out
# afterward with whatever identity is actually available today (ad hoc, or
# Developer ID once its secrets exist). Keeping build and sign separate means
# this script never has to know or care whether Developer ID secrets exist.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "Building $SCHEME $VERSION ($BUILD_NUMBER) — Release configuration"
xcodebuild build \
  -project "$PROJECT_FILE" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

[[ -d "$APP_PATH" ]] || die "build succeeded but $APP_PATH is missing"
log "Built $APP_PATH"

# 851-2475: fail the release before signing/notarizing if the appex lost its
# AutoFill capabilities (XcodeGen strips anything project.yml doesn't declare).
"$(dirname "${BASH_SOURCE[0]}")/verify-autofill-plist.sh" "$APP_PATH"
