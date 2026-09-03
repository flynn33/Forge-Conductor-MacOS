#!/usr/bin/env python3
from __future__ import annotations
import json
import subprocess
from pathlib import Path

root = Path(subprocess.check_output(
    ["git", "rev-parse", "--show-toplevel"], text=True
).strip())
graph = json.loads((root / ".forge-e2/work/work-packages.json").read_text())
state_path = root / ".forge-e2-state/run-state.json"
state = json.loads(state_path.read_text())

for item in graph["packages"]:
    record = state["work"].get(item["id"], {"status":"pending"})
    if record["status"] == "passed":
        continue
    dependencies = [state["work"].get(d, {}).get("status") for d in item["depends_on"]]
    if all(s == "passed" for s in dependencies):
        state["active_work_id"] = item["id"]
        state_path.write_text(json.dumps(state, indent=2) + "\n")
        print(json.dumps(item, indent=2))
        raise SystemExit(0)

if all(v["status"] == "passed" for v in state["work"].values()):
    print("All work packages passed. Run validate_completion.py.")
else:
    print("No unblocked work package. Inspect failed dependency evidence.")
    raise SystemExit(2)
