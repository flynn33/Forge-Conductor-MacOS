#!/bin/bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

python3 .forge-e2/scripts/validate_package.py \
  --root .forge-e2 \
  --allow-missing-input-archive
python3 .forge-e2/scripts/verify_baseline.py --repo .
python3 .forge-e2/scripts/doctor.py
python3 .forge-e2/scripts/initialize_run_state.py
python3 .forge-e2/scripts/select_next_work.py

cat <<'MESSAGE'

Read .forge-e2/CODEX-START-HERE.md and begin the selected work package.
Do not ask the operator for implementation choices. Preserve evidence and fail forward.
MESSAGE
