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
    (umask 077 && printf '%s' "$NOTARY_API_KEY_P8" >"$key_path")
    notary_args=(--key "$key_path" --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_API_ISSUER_ID")
  else
    notary_args=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$APPLE_TEAM_ID")
  fi

  # notarytool can't take a bare .app: submit a zip of it, then staple the app.
  local submit_path="$target"
  if [[ -d "$target" ]]; then
    submit_path="$SCRATCH_DIR/notarize-$(basename "$target").zip"
    rm -f "$submit_path"
    ditto -c -k --keepParent "$target" "$submit_path"
  fi

  # Capture the status explicitly (not `|| die`) so the API key and zip are
  # deleted on every path before bailing — `die` exits the whole process, so
  # a RETURN trap would never run (851-2474).
  local result status=0
  result="$(xcrun notarytool submit "$submit_path" "${notary_args[@]}" --wait 2>&1)" || status=$?
  rm -f "$SCRATCH_DIR/notary-api-key.p8"
  [[ "$submit_path" != "$target" ]] && rm -f "$submit_path"
  printf '%s\n' "$result" >&2
  [[ $status -eq 0 ]] || die "notarytool submit failed for $target (exit $status)"
  grep -q 'status: Accepted' <<<"$result" || die "Notarization of $target was not Accepted — see \`xcrun notarytool log <id>\` for the submission id above"

  log "Stapling $target"
  xcrun stapler staple "$target"
}
