#!/usr/bin/env python3
from __future__ import annotations
import argparse, hashlib, json, subprocess
from datetime import datetime, timezone
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("--work-id", required=True)
p.add_argument("--status", choices=["pending","in_progress","blocked","failed","passed"], required=True)
p.add_argument("--evidence", action="append", default=[])
args = p.parse_args()

root = Path(subprocess.check_output(["git","rev-parse","--show-toplevel"], text=True).strip())
state_path = root / ".forge-e2-state/run-state.json"
state = json.loads(state_path.read_text())
record = state["work"][args.work_id]
record["status"] = args.status
record["attempts"] = record.get("attempts", 0) + (1 if args.status in {"failed","blocked"} else 0)

for raw in args.evidence:
    path = Path(raw)
    if not path.is_absolute():
        path = root / path
    data = path.read_bytes()
    record.setdefault("evidence", []).append({
        "path": str(path.relative_to(root)) if path.is_relative_to(root) else str(path),
        "sha256": hashlib.sha256(data).hexdigest(),
        "bytes": len(data)
    })
state["last_updated_at"] = datetime.now(timezone.utc).isoformat()
state_path.write_text(json.dumps(state, indent=2) + "\n")
print(state_path)
