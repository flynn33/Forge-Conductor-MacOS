#!/usr/bin/env bash
set -euo pipefail
ROOT="${FORGE_GATE_REPOSITORY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
"$ROOT/.forge-codex/scripts/validate_acceptance.py" G07 --repo "$ROOT" --criteria-output "$ROOT/.forge-codex/state/gate-results/G07.criteria.json"
