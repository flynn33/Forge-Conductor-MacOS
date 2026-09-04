#!/bin/bash
set -euo pipefail
PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/Forge-Conductor" >&2
  exit 64
fi
python3 "$PACKAGE_DIR/scripts/validate_package.py"
python3 "$PACKAGE_DIR/scripts/install_into_repo.py" "$1"
python3 "$1/.forge-qwen-remediation/scripts/doctor.py" --repo "$1"
python3 "$1/.forge-qwen-remediation/scripts/static_contract_checks.py" \
  --repo "$1" || true
