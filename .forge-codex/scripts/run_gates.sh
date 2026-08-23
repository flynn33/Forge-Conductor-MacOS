#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:---ready}"
STATE="$ROOT/.forge-codex/state/run-state.json"
PLAN="$ROOT/.forge-codex/plans/phases.json"

[[ -f "$STATE" ]] || "$ROOT/.forge-codex/scripts/statectl.py" init >/dev/null

GATE_LIST="$(python3 - "$STATE" "$PLAN" "$MODE" <<'PY'
import json,sys
state=json.load(open(sys.argv[1]))
plan=json.load(open(sys.argv[2]))
mode=sys.argv[3]
passed={p for p,v in state["phases"].items() if v["status"]=="passed"}
for phase in sorted(plan["phases"],key=lambda p:(-p["priority"],p["id"])):
    if mode=="--all" or all(dep in passed for dep in phase["dependencies"]):
        for gate in phase["hard_gates"]:
            if mode=="--all" or state["gates"][gate]["status"]!="passed":
                print(gate)
PY
)"

failures=0
while IFS= read -r gate; do
  [[ -n "$gate" ]] || continue
  "$ROOT/.forge-codex/scripts/run_gate.py" "$gate" --repo "$ROOT" || failures=$((failures+1))
done <<EOF
$GATE_LIST
EOF
exit "$failures"
