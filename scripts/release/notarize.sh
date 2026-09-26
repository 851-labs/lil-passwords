# Library: notarize_and_staple <path>. Sourced by make-dmg.sh, not run
# directly. No-ops with a warning (not a failure — see the pipeline's whole
# point, 851-2436) when notarization credentials aren't configured, or when
# there's no Developer ID identity to have signed with in the first place.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

notarize_and_staple() {
  local target="$1"

  if [[ "$(signing_identity)" == "-" ]]; then
    warn "Ad hoc signed — skipping notarization (Apple rejects ad hoc submissions). Configure DEVELOPER_ID_CERT_P12/DEVELOPER_ID_CERT_PASSWORD to enable. See docs/releasing.md and 851-2436."
    return 0
  fi

  if ! has_notary_credentials; then
    warn "No notarization credentials (NOTARY_APPLE_ID+NOTARY_PASSWORD, or NOTARY_API_KEY_ID+NOTARY_API_ISSUER_ID+NOTARY_API_KEY_P8) — skipping notarization. $target will fail Gatekeeper on other Macs. See docs/releasing.md and 851-2436."
    return 0
  fi

  log "Submitting $target for notarization"
  local notary_args=()
  if [[ -n "${NOTARY_API_KEY_ID:-}" ]]; then
    local key_path="$SCRATCH_DIR/notary-api-key.p8"
    printf '%s' "$NOTARY_API_KEY_P8" >"$key_path"
    trap 'rm -f "$key_path"' RETURN
    notary_args=(--key "$key_path" --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_API_ISSUER_ID")
  else
    notary_args=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$APPLE_TEAM_ID")
  fi

  xcrun notarytool submit "$target" "${notary_args[@]}" --wait

  log "Stapling $target"
  xcrun stapler staple "$target"
}
