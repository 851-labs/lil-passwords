#!/usr/bin/env bash
# Generates dist/appcast.xml for the DMG built by make-dmg.sh.
#
# Downloads the `generate_appcast` CLI tool from the Sparkle GitHub release
# that matches the version pinned in Package.resolved (that binary isn't part
# of the SPM package — see Sparkle-for-Swift-Package-Manager.zip in Sparkle's
# release assets), pulls the previous release's appcast.xml (if any) into the
# same directory as the new DMG so old <item>s are preserved rather than
# clobbered, then signs the new entry with SPARKLE_ED_PRIVATE_KEY.
#
# No-ops with a warning (not a failure) if SPARKLE_ED_PRIVATE_KEY isn't set —
# see docs/releasing.md for `generate_keys` and how to provision the secret.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ -f "$DMG_PATH" ]] || die "$DMG_PATH not found — run make-dmg.sh first"

if [[ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  warn "SPARKLE_ED_PRIVATE_KEY is not set — skipping appcast generation. Installed apps won't see this release via Sparkle. See docs/releasing.md."
  exit 0
fi

PACKAGE_RESOLVED="LilPasswords.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
[[ -f "$PACKAGE_RESOLVED" ]] || die "$PACKAGE_RESOLVED not found — run 'xcodegen generate' (or 'make project') first"

SPARKLE_VERSION="$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(next(p["state"]["version"] for p in data["pins"] if p["identity"] == "sparkle"))
' "$PACKAGE_RESOLVED")"
[[ -n "$SPARKLE_VERSION" ]] || die "Could not find a 'sparkle' pin in $PACKAGE_RESOLVED"
log "Sparkle version (from Package.resolved): $SPARKLE_VERSION"

TOOLS_DIR="$SCRATCH_DIR/sparkle-tools-$SPARKLE_VERSION"
GENERATE_APPCAST="$TOOLS_DIR/bin/generate_appcast"
if [[ ! -x "$GENERATE_APPCAST" ]]; then
  log "Downloading Sparkle $SPARKLE_VERSION command line tools"
  rm -rf "$TOOLS_DIR"
  mkdir -p "$TOOLS_DIR"
  curl -fsSL -o "$SCRATCH_DIR/sparkle-tools.zip" \
    "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-for-Swift-Package-Manager.zip"
  ditto -x -k "$SCRATCH_DIR/sparkle-tools.zip" "$TOOLS_DIR"
  # The zip nests a top-level "bin/" (and "Sparkle.framework" etc.) — find it
  # rather than assuming an exact path in case Sparkle changes the layout.
  FOUND="$(find "$TOOLS_DIR" -type f -name generate_appcast -perm -u+x -print -quit)"
  [[ -n "$FOUND" ]] || die "generate_appcast not found inside Sparkle-for-Swift-Package-Manager.zip for $SPARKLE_VERSION"
  GENERATE_APPCAST="$FOUND"
fi

APPCAST_WORKDIR="$SCRATCH_DIR/appcast"
rm -rf "$APPCAST_WORKDIR"
mkdir -p "$APPCAST_WORKDIR"
cp "$DMG_PATH" "$APPCAST_WORKDIR/"

TAG="v${VERSION}"
DOWNLOAD_PREFIX="https://github.com/${GITHUB_REPO}/releases/download/${TAG}/"

# Pull the previous release's appcast.xml, if there is one, into
# $APPCAST_WORKDIR/appcast.xml — generate_appcast's default output filename —
# so it updates/merges rather than starting a feed from scratch.
if command -v gh >/dev/null 2>&1 && { [[ -n "${GH_TOKEN:-}" ]] || [[ -n "${GITHUB_TOKEN:-}" ]]; }; then
  PREV_TAG="$(gh release list --repo "$GITHUB_REPO" --exclude-drafts --exclude-pre-releases \
    --json tagName,createdAt --jq "[.[] | select(.tagName != \"$TAG\")] | sort_by(.createdAt) | last | .tagName" 2>/dev/null || true)"
  if [[ -n "$PREV_TAG" && "$PREV_TAG" != "null" ]]; then
    log "Pulling previous appcast.xml from $PREV_TAG to preserve older entries in the feed"
    gh release download "$PREV_TAG" --repo "$GITHUB_REPO" --pattern 'appcast.xml' --dir "$APPCAST_WORKDIR" --clobber 2>/dev/null \
      || warn "Could not download appcast.xml from $PREV_TAG — generating a feed with only this release's entry."
  else
    log "No previous release found — this will be the first appcast entry."
  fi
else
  warn "gh not available/authenticated — generating a feed with only this release's entry."
fi

log "Running generate_appcast"
"$GENERATE_APPCAST" --ed-key-file - \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  "$APPCAST_WORKDIR" <<<"$SPARKLE_ED_PRIVATE_KEY"

[[ -f "$APPCAST_WORKDIR/appcast.xml" ]] || die "generate_appcast did not produce appcast.xml in $APPCAST_WORKDIR"
mkdir -p "$DIST_DIR"
cp "$APPCAST_WORKDIR/appcast.xml" "$DIST_DIR/appcast.xml"

log "appcast ready: $DIST_DIR/appcast.xml"
