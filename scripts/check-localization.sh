#!/usr/bin/env bash
# Thin wrapper around check-localization.py (851-2466) — kept as the `scripts/check-localization.sh`
# entry point `make lint`/CI actually call, so the check has a stable, discoverable name even though
# the implementation itself is Python (easier to write/maintain correctly than the equivalent
# bracket-matching in bash/awk — see check-localization.py's module docstring for why this can't just
# be a handful of grep patterns).
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/check-localization.py" "$@"
