#!/usr/bin/env bash
set -euo pipefail
ROOT="${FORGE_GATE_REPOSITORY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
PKG="$ROOT/.forge-codex"
RESULT="$PKG/state/gate-results"
BASE="$PKG/state/baseline"
mkdir -p "$RESULT"
"$PKG/scripts/feature_inventory.py" --repo "$ROOT" --output "$RESULT/G01.static-inventory.json" > "$RESULT/G01.inventory.log"
python3 - "$ROOT" "$RESULT" "$BASE" <<'PY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]);out=Path(sys.argv[2]);base=Path(sys.argv[3])
inv=root/".forge-codex/state/feature-baseline.json"
d=json.load(open(inv))
def a(p):
 p=Path(p);return {"path":str(p),"sha256":hashlib.sha256(p.read_bytes()).hexdigest()}
needed=[base/"mcp-capabilities.json",base/"persistence-inventory.json",base/"characterization-tests.json"]
mcp,persistence,characterization=(json.load(open(path)) for path in needed)
features=d.get("features",[])
features_valid=all(
 isinstance(feature,dict)
 and feature.get("id")
 and feature.get("category")
 and feature.get("baseline_status") in {"present","present_broken"}
 and feature.get("parity_status") in {"preserved","additive","migrated"}
 and feature.get("evidence")
 for feature in features
)
criteria=[
 {"criterion":"feature-baseline.json validates","passed":len(features)>0 and features_valid and d.get("runtime_completion_required") is False,"evidence":[a(inv)]},
 {"criterion":"existing MCP surfaces captured","passed":bool(mcp.get("captured_at") and mcp.get("initialize_transcript_artifact") and mcp.get("tools")),"evidence":[a(needed[0])]},
 {"criterion":"persistence/settings/commands/scenes inventoried","passed":bool(persistence.get("captured_at") and persistence.get("files_and_directories") and persistence.get("databases")),"evidence":[a(needed[1])]},
 {"criterion":"all behavior-changing targets have characterization coverage","passed":bool(characterization.get("captured_at") and characterization.get("tests") and characterization.get("affected_feature_coverage_complete") is True),"evidence":[a(needed[2])]},
]
json.dump({"criteria_results":criteria},open(out/"G01.criteria.json","w"),indent=2)
if not all(c["passed"] and c["evidence"] for c in criteria):raise SystemExit(1)
PY
