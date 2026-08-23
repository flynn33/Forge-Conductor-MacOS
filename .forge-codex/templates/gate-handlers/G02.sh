#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
"$ROOT/.forge-codex/scripts/validate_acceptance.py" G02 --repo "$ROOT" --criteria-output "$ROOT/.forge-codex/state/gate-results/G02.criteria.json"
