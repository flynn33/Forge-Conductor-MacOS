#!/usr/bin/env bash
set -euo pipefail
ROOT="${FORGE_GATE_REPOSITORY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
CRITERIA_OUTPUT="$ROOT/.forge-codex/state/gate-results/G10.criteria.json"
/bin/rm -f -- "$CRITERIA_OUTPUT"
FORGE_P10_REPOSITORY="$ROOT" \
  "$ROOT/.forge-codex/scripts/check_p10_completion.py"
"$ROOT/.forge-codex/scripts/validate_acceptance.py" G10 --repo "$ROOT" --criteria-output "$CRITERIA_OUTPUT"
