#!/usr/bin/env python3
from __future__ import annotations
import json, subprocess
from pathlib import Path

root = Path(subprocess.check_output(["git","rev-parse","--show-toplevel"], text=True).strip())
state = json.loads((root / ".forge-e2-state/run-state.json").read_text())
gates = json.loads((root / ".forge-e2/work/acceptance-gates.json").read_text())

errors = []
for work_id, record in state["work"].items():
    if record["status"] != "passed":
        errors.append(f"work {work_id}: {record['status']}")
for gate in gates["gates"]:
    record = state["gates"].get(gate["id"], {})
    if gate["hard"] and record.get("status") != "passed":
        errors.append(f"gate {gate['id']}: {record.get('status','missing')}")
if "FC-FILESYSTEM-PATH-TOCTOU-001" in state.get("open_findings", []):
    errors.append("E2 finding remains open")

if errors:
    print("\n".join(errors))
    raise SystemExit(1)
print("E2 completion state is internally complete. Verify evidence hashes and PR status.")
