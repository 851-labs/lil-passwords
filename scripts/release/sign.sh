#!/usr/bin/env bash
# Signs the app inside out: Sparkle's bundled helper tools first, then the
# embedded agent and CLI (Contents/Helpers, see project.yml), then the app
# itself last (its seal covers everything already signed inside it). Every
# target gets its own entitlements (all three are intentionally empty — see
# docs/adr/0001).
#
# Uses whatever scripts/release/lib.sh's signing_identity() returns: ad hoc
# ("-") today, or a real "Developer ID Application: ..." identity once
# DEVELOPER_ID_CERT_P12/DEVELOPER_ID_CERT_PASSWORD exist (APPLE_TEAM_ID
# defaults to Alexandru Turcanu's team, WH4QW9ND3J — see lib.sh).
#
# Hardened runtime (`--options runtime`) is only applied with a real Developer
# ID identity, NOT ad hoc. This isn't just "the only thing that changes" —
# it's load-bearing: hardened runtime turns on dyld library validation, which
# requires a loaded non-platform binary to share the *same Team ID* as the
# process loading it. Ad hoc signatures carry no Team ID at all, and two
# independently ad-hoc-signed Mach-O objects (e.g. the app binary and the
# Sparkle.framework dylib, signed in separate codesign invocations below) are
# never considered a match — so a hardened-runtime + ad-hoc build fails at
# launch with "Library not loaded: ... different Team IDs", even though
# `codesign --verify --deep --strict` reports it as perfectly valid (that
# check doesn't simulate dyld's runtime library-validation policy at all).
# Once a real Developer ID identity signs everything with one matching Team
# ID, hardened runtime works exactly as intended (and notarization requires
# it), so this only ever removes protection from builds that have no
# meaningful identity to protect in the first place.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ -d "$APP_PATH" ]] || die "$APP_PATH not found — run build.sh first"

IDENTITY="$(signing_identity)"
if [[ "$IDENTITY" == "-" ]]; then
  warn "Signing ad hoc ('-') — no Developer ID cert configured yet (851-2436). This build will fail Gatekeeper on other Macs, and skips hardened runtime (see comment above) so it can still launch locally."
else
  log "Signing with Developer ID identity: $IDENTITY"
fi

# Every codesign call goes through here. With a real identity: hardened
# runtime + secure timestamp (both required for notarization), and an
# explicit --keychain so codesign resolves the identity (by SHA-1, see
# import-certificate.sh) from the scratch keychain rather than whatever the
# user's search list happens to contain. Two branches rather than a flags
# array: macOS's /bin/bash 3.2 treats expanding an empty array under `set -u`
# as an unbound-variable error.
run_codesign() {
  if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - "$@"
  else
    codesign --force --options runtime --timestamp --keychain "$SIGNING_KEYCHAIN_PATH" --sign "$IDENTITY" "$@"
  fi
}

codesign_plain() {
  local target="$1"
  log "codesign: ${target#"$APP_PATH"/}"
  run_codesign "$target"
}

codesign_with_entitlements() {
  local target="$1" entitlements="$2"
  log "codesign: ${target#"$APP_PATH"/} ($entitlements)"
  run_codesign --entitlements "$entitlements" "$target"
}

# 851-2465: `LilPasswordsAgent` and `lilpass` are bare `com.apple.product-type.tool` binaries with
# no Info.plist (see project.yml's matching comment on their `OTHER_CODE_SIGN_FLAGS`) — with no
# CFBundleIdentifier anywhere in the binary, a plain `codesign` here would silently fall back to
# each executable's own file name ("LilPasswordsAgent"/"lilpass") as its signing identifier instead
# of the bundle identifier `AgentConnectionSecurity` (Packages/LilPasswordsKit) actually checks for
# (`com.851labs.lilpasswords.agent`/`.cli`). That's invisible with ad hoc signing (no Team ID to
# check against in the first place — `AgentConnectionSecurity.Requirement.developmentFallback`
# accepts anything), but the moment this runs with a real identity, the app and the agent reject
# every connection from each other — confirmed via a real Apple Development-signed install to
# /Applications during 851-2465's real-install smoke test.
codesign_with_entitlements_and_identifier() {
  local target="$1" entitlements="$2" identifier="$3"
  log "codesign: ${target#"$APP_PATH"/} ($entitlements, -i $identifier)"
  run_codesign --identifier "$identifier" --entitlements "$entitlements" "$target"
}

# --- 1. Sparkle.framework's bundled helper tools ---------------------------
# Sparkle ships its own Autoupdate tool, a small Updater.app, and two XPC
# services alongside its versioned dylib. These are independent code objects
# nested inside the framework bundle and each needs its own signature before
# the framework (and later the app) is sealed over them. `Versions/Current` is
# a symlink Sparkle maintains itself, so this survives Sparkle version bumps
# without hardcoding a version letter.
SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
  for nested in \
    "$SPARKLE_FRAMEWORK/Versions/Current/Autoupdate" \
    "$SPARKLE_FRAMEWORK/Versions/Current/Updater.app" \
    "$SPARKLE_FRAMEWORK/Versions/Current/XPCServices/Downloader.xpc" \
    "$SPARKLE_FRAMEWORK/Versions/Current/XPCServices/Installer.xpc"; do
    [[ -e "$nested" ]] || continue
    codesign_plain "$nested"
  done
  codesign_plain "$SPARKLE_FRAMEWORK"
else
  warn "Sparkle.framework not found in $APP_PATH — was it embedded? (851-2437)"
fi

# --- 2. Embedded helper tools (Contents/Helpers) ----------------------------
AGENT_PATH="$APP_PATH/Contents/Helpers/LilPasswordsAgent"
CLI_PATH="$APP_PATH/Contents/Helpers/lilpass"
[[ -f "$AGENT_PATH" ]] || die "$AGENT_PATH not found — was LilPasswordsAgent embedded?"
[[ -f "$CLI_PATH" ]] || die "$CLI_PATH not found — was lilpass embedded?"
codesign_with_entitlements_and_identifier "$AGENT_PATH" "Config/Entitlements/Agent.entitlements" "com.851labs.lilpasswords.agent"
codesign_with_entitlements_and_identifier "$CLI_PATH" "Config/Entitlements/CLI.entitlements" "com.851labs.lilpasswords.cli"

# --- 3. The AutoFill credential provider extension (Contents/PlugIns) -------
# 851-2474: without this the appex kept the build's ad hoc signature, and
# notarization rejected the whole app ("not signed with a valid Developer ID
# certificate" / "does not include a secure timestamp" on AutoFill.appex).
# Same entitlements project.yml's post-embed re-sign applies (851-2441).
#
# 851-2476: the appex carries the *restricted*
# com.apple.developer.authentication-services.autofill-credential-provider
# entitlement, so with a real Developer ID identity AMFI only lets it launch if
# the bundle embeds a Developer ID provisioning profile from the same team that
# allows every restricted entitlement it's signed with. prepare-autofill-profile.sh
# decodes AUTOFILL_PROVISIONING_PROFILE, checks it, copies it to
# Contents/embedded.provisionprofile, and writes the entitlements to sign with:
# the base file plus com.apple.application-identifier and
# com.apple.developer.team-identifier, which a provisioned macOS extension must
# carry in its signature (the profile's keychain-access-groups is an allowance,
# not a requirement, so it isn't added). The profile is copied in *before*
# codesign so the appex's seal covers it.
#
# Profile missing with a Developer ID identity: the appex is left out of the
# build (loud warning + GitHub Actions annotation) rather than shipped
# unprovisioned. An unprovisioned copy would still register with pluginkit and
# show up in System Settings → AutoFill & Passwords, and then AMFI would kill it
# the moment the user picked it: a broken feature that looks like it works.
# Leaving it out ships a working app without AutoFill instead. Ad hoc builds
# (no cert) keep the appex unprovisioned as before: a Developer ID profile
# can't apply to an ad hoc signature anyway.
AUTOFILL_PATH="$APP_PATH/Contents/PlugIns/AutoFill.appex"
AUTOFILL_ENTITLEMENTS="Config/Entitlements/AutoFillExtension.entitlements"
[[ -d "$AUTOFILL_PATH" ]] || die "$AUTOFILL_PATH not found — was AutoFillExtension embedded?"
if [[ "$IDENTITY" == "-" ]]; then
  codesign_with_entitlements "$AUTOFILL_PATH" "$AUTOFILL_ENTITLEMENTS"
elif [[ -z "${AUTOFILL_PROVISIONING_PROFILE:-}" ]]; then
  message="AUTOFILL_PROVISIONING_PROFILE is not set: leaving AutoFill.appex OUT of this Developer ID build. An unprovisioned appex carrying the restricted autofill-credential-provider entitlement would register in System Settings and then be killed by AMFI on launch. This release ships without the AutoFill extension. See docs/releasing.md (851-2476)."
  warn "$message"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning title=AutoFill extension left out::$message"
  fi
  rm -rf "$AUTOFILL_PATH"
  rmdir "$APP_PATH/Contents/PlugIns" 2>/dev/null || true
else
  SIGNED_ENTITLEMENTS="$("$(dirname "${BASH_SOURCE[0]}")/prepare-autofill-profile.sh" "$AUTOFILL_PATH" "$AUTOFILL_ENTITLEMENTS" "$IDENTITY")"
  codesign_with_entitlements "$AUTOFILL_PATH" "$SIGNED_ENTITLEMENTS"
  "$(dirname "${BASH_SOURCE[0]}")/verify-autofill-profile.sh" "$AUTOFILL_PATH"
fi

# --- 4. The app itself, last ------------------------------------------------
codesign_with_entitlements "$APP_PATH" "Config/Entitlements/App.entitlements"

log "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ "$IDENTITY" != "-" ]]; then
  log "Gatekeeper assessment (informational until notarized+stapled):"
  spctl --assess --type execute --verbose=4 "$APP_PATH" || warn "spctl assessment failed — expected until this build is notarized and stapled."
fi

log "Signed $APP_PATH"
