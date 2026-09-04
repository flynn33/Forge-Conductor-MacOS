#!/usr/bin/env python3
from __future__ import annotations
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

root = Path(subprocess.check_output(
    ["git", "rev-parse", "--show-toplevel"], text=True
).strip())
state_dir = root / ".forge-e2-state"
state_dir.mkdir(parents=True, exist_ok=True)
state_path = state_dir / "run-state.json"
template = root / ".forge-e2" / "work" / "state-template.json"

if not state_path.exists():
    state_path.write_text(template.read_text(encoding="utf-8"), encoding="utf-8")

state = json.loads(state_path.read_text(encoding="utf-8"))
state["baseline"] = {
    "head": subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
    ).strip(),
    "branch": subprocess.check_output(
        ["git", "-C", str(root), "branch", "--show-current"], text=True
    ).strip(),
    "recorded_at": datetime.now(timezone.utc).isoformat(),
}
state["last_updated_at"] = datetime.now(timezone.utc).isoformat()
state_path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
print(state_path)
