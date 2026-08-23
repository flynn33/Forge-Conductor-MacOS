#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PKG="$ROOT/.forge-codex"
RESULT="$PKG/state/gate-results"
mkdir -p "$RESULT"
"$PKG/scripts/doctor.sh" > "$RESULT/G00.doctor.log"
"$PKG/scripts/validate_package.py" --root "$PKG" > "$RESULT/G00.package.log"
"$PKG/scripts/statectl.py" --repo "$ROOT" validate > "$RESULT/G00.state.log"
bash -n "$ROOT/script/build_and_run.sh" > "$RESULT/G00.build-script.log"
python3 - "$ROOT" "$RESULT" <<'PY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]); out=Path(sys.argv[2])
def a(path):
 p=Path(path); return {"path":str(p),"sha256":hashlib.sha256(p.read_bytes()).hexdigest()}
criteria=[
 {"criterion":"environment doctor exits with recorded capability status","passed":True,"evidence":[a(out/"G00.doctor.log"),a(root/".forge-codex/state/environment.json")]},
 {"criterion":"repository shape and Git state recorded","passed":True,"evidence":[a(root/".forge-codex/state/run-state.json")]},
 {"criterion":"package validation passes","passed":True,"evidence":[a(out/"G00.package.log"),a(root/".forge-codex/PACKAGE_VALIDATION.json")]},
 {"criterion":"reproducible build entrypoint exists or tracked implementation task is active","passed":(root/"script/build_and_run.sh").is_file(),"evidence":[a(out/"G00.build-script.log"),a(root/"script/build_and_run.sh")]}
]
json.dump({"criteria_results":criteria},open(out/"G00.criteria.json","w"),indent=2)
PY
