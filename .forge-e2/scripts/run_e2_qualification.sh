#!/bin/bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
EVIDENCE_DIR=".forge-e2-state/evidence"
mkdir -p "$EVIDENCE_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

run() {
  local name="$1"
  shift
  set +e
  "$@" >"$EVIDENCE_DIR/$STAMP-$name.stdout.txt" \
       2>"$EVIDENCE_DIR/$STAMP-$name.stderr.txt"
  local code=$?
  set -e
  python3 - "$name" "$code" "$EVIDENCE_DIR" "$STAMP" "$@" <<'PY'
import hashlib, json, sys
from pathlib import Path
name, code, evidence, stamp, *command = sys.argv[1:]
base = Path(evidence)
record = {
  "schema_version": 1,
  "name": name,
  "exit_code": int(code),
  "command": command,
  "stdout_sha256": hashlib.sha256((base/f"{stamp}-{name}.stdout.txt").read_bytes()).hexdigest(),
  "stderr_sha256": hashlib.sha256((base/f"{stamp}-{name}.stderr.txt").read_bytes()).hexdigest(),
}
(base/f"{stamp}-{name}.json").write_text(json.dumps(record, indent=2)+"\n")
PY
  return "$code"
}

run baseline python3 .forge-e2/scripts/verify_baseline.py --repo . --allow-dirty
run api-probe ./.forge-e2/scripts/run_macos_api_probe.sh
run swift-filesystem swift test --filter Filesystem
run swift-shell swift test --filter Shell
run swift-project-memory swift test --filter ProjectMemory
run swift-continuity swift test --filter Continuity
run swift-autonomy swift test --filter Autonomy
run swift-manager swift test --filter Manager
run swift-all-serial swift test --no-parallel
run swift-all-parallel swift test --parallel
run source-guard python3 .forge-e2/scripts/source_guard.py .
run shell-preservation python3 .forge-e2/scripts/check_shell_preservation.py
run attribution python3 .forge-e2/scripts/check_attribution.py .
run secrets python3 .forge-e2/scripts/secret_scan.py .

printf 'Qualification evidence written under %s\n' "$EVIDENCE_DIR"
