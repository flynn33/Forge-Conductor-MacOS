#!/bin/bash
set -euo pipefail
PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${1:-$PACKAGE_DIR/work}"
TARGET="$WORK_ROOT/Forge-Conductor-MacOS-main"
python3 "$PACKAGE_DIR/scripts/validate_package.py"
mkdir -p "$WORK_ROOT"
if [[ -e "$TARGET" ]]; then
  mv "$TARGET" "$TARGET.backup-$(date -u +%Y%m%dT%H%M%SZ)"
fi
/usr/bin/unzip -q \
  "$PACKAGE_DIR/inputs/Forge-Conductor-MacOS-main.zip" \
  -d "$WORK_ROOT"
rm -rf "$WORK_ROOT/__MACOSX"
python3 "$PACKAGE_DIR/scripts/install_into_repo.py" "$TARGET"
python3 "$TARGET/.forge-qwen-remediation/scripts/doctor.py" \
  --repo "$TARGET"
python3 "$TARGET/.forge-qwen-remediation/scripts/static_contract_checks.py" \
  --repo "$TARGET" || true
printf '\nRepository ready: %s\n' "$TARGET"
printf 'Start a loopback Qwen3.8-27B 4-bit server, then run:\n'
printf '  cd %q && ./.forge-qwen-remediation/scripts/run_qwen_autonomously.sh .\n' "$TARGET"
