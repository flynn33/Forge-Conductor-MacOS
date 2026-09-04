#!/usr/bin/env python3
from __future__ import annotations
import argparse
import hashlib
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--gate-id", required=True)
parser.add_argument("--status", required=True, choices=["pending", "running", "blocked", "failed", "passed"])
parser.add_argument("--evidence", action="append", default=[])
parser.add_argument("--note")
args = parser.parse_args()

root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
state_path = root / ".forge-e2-state/run-state.json"
state = json.loads(state_path.read_text())
known = {item["id"] for item in json.loads((root / ".forge-e2/work/acceptance-gates.json").read_text())["gates"]}
if args.gate_id not in known:
    raise SystemExit(f"unknown gate: {args.gate_id}")

receipts = []
for raw in args.evidence:
    path = Path(raw)
    if not path.is_absolute():
        path = root / path
    data = path.read_bytes()
    receipts.append({
        "path": str(path.relative_to(root)) if path.is_relative_to(root) else str(path),
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    })

state.setdefault("gates", {})[args.gate_id] = {
    "status": args.status,
    "recorded_at": datetime.now(timezone.utc).isoformat(),
    "evidence": receipts,
    "note": args.note,
}
state["last_updated_at"] = datetime.now(timezone.utc).isoformat()
state_path.write_text(json.dumps(state, indent=2) + "\n")
print(json.dumps(state["gates"][args.gate_id], indent=2))
