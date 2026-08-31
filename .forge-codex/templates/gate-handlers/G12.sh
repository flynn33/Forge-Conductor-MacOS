#!/usr/bin/env bash
set -euo pipefail

ROOT="${FORGE_GATE_REPOSITORY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
CRITERIA="$ROOT/.forge-codex/state/gate-results/G12.criteria.json"

exec python3 "$ROOT/.forge-codex/scripts/verify_completion.py" \
  --repo "$ROOT" \
  --no-finalize \
  --criteria-output "$CRITERIA"
