#!/usr/bin/env bash
set -euo pipefail
ROOT="${FORGE_GATE_REPOSITORY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
"$ROOT/.forge-codex/scripts/validate_acceptance.py" G11 --repo "$ROOT" --criteria-output "$ROOT/.forge-codex/state/gate-results/G11.criteria.json"
