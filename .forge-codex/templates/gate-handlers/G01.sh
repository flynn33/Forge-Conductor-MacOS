#!/usr/bin/env bash
set -euo pipefail
ROOT="${FORGE_GATE_REPOSITORY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
PKG="$ROOT/.forge-codex"
RESULT="$PKG/state/gate-results"
BASE="$PKG/state/baseline"
mkdir -p "$RESULT"
"$PKG/scripts/feature_inventory.py" --repo "$ROOT" --output "$RESULT/G01.current-static-inventory.json" > "$RESULT/G01.inventory.log"
python3 - "$ROOT" "$RESULT" "$BASE" <<'PY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]);out=Path(sys.argv[2]);base=Path(sys.argv[3])
inv=root/".forge-codex/state/feature-baseline.json"
sys.path.insert(0,str(root/".forge-codex/scripts"))
from evidence_support import decode_strict_json_object,source_manifest
from p10_feature_baseline import (
 FEATURE_BASELINE_PATH,FEATURE_REGISTRY_PATH,HISTORICAL_STATIC_INVENTORY_PATH,
 EXPECTED_HISTORICAL_STATIC_INVENTORY_SHA256,validate_feature_baseline,
)
def load(relative):
 raw=(root/relative).read_bytes()
 return decode_strict_json_object(raw,label=relative),raw
def binding(relative,raw):
 return {"path":relative,"sha256":hashlib.sha256(raw).hexdigest(),"bytes":len(raw)}
d,_=load(FEATURE_BASELINE_PATH)
registry,registry_raw=load(FEATURE_REGISTRY_PATH)
historical,historical_raw=load(HISTORICAL_STATIC_INVENTORY_PATH)
historical_binding={
 **binding(HISTORICAL_STATIC_INVENTORY_PATH,historical_raw),
 "schema_version":historical.get("schema_version"),
 "feature_count":len(historical.get("features",[])),
 "parity_summary":historical.get("parity_summary"),
 "authority":"historical_discovery_only",
}
evaluation=validate_feature_baseline(
 d,registry=registry,registry_artifact=binding(FEATURE_REGISTRY_PATH,registry_raw),
 current_source_snapshot=source_manifest(root,excluded_paths=(FEATURE_BASELINE_PATH,)),
 historical_inventory_artifact=historical_binding,
)
inventory_failures=list(evaluation.inventory_failures)
if historical_binding["sha256"] != EXPECTED_HISTORICAL_STATIC_INVENTORY_SHA256:
 inventory_failures.append("historical static inventory does not match its pinned identity")
# G01 validates the inventory; P10 separately enforces every runtime completion blocker.
for failure in inventory_failures:print(failure)
def a(p):
 p=Path(p);return {"path":str(p),"sha256":hashlib.sha256(p.read_bytes()).hexdigest()}
needed=[base/"mcp-capabilities.json",base/"persistence-inventory.json",base/"characterization-tests.json"]
mcp,persistence,characterization=(json.load(open(path)) for path in needed)
criteria=[
 {"criterion":"feature-baseline.json validates","passed":not inventory_failures,"evidence":[a(inv)]},
 {"criterion":"existing MCP surfaces captured","passed":bool(mcp.get("captured_at") and mcp.get("initialize_transcript_artifact") and mcp.get("tools")),"evidence":[a(needed[0])]},
 {"criterion":"persistence/settings/commands/scenes inventoried","passed":bool(persistence.get("captured_at") and persistence.get("files_and_directories") and persistence.get("databases")),"evidence":[a(needed[1])]},
 {"criterion":"all behavior-changing targets have characterization coverage","passed":bool(characterization.get("captured_at") and characterization.get("tests") and characterization.get("affected_feature_coverage_complete") is True),"evidence":[a(needed[2])]},
]
json.dump({"criteria_results":criteria},open(out/"G01.criteria.json","w"),indent=2)
if not all(c["passed"] and c["evidence"] for c in criteria):raise SystemExit(1)
PY
