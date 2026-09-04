#!/usr/bin/env python3
from __future__ import annotations
import json
import os
import platform
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

def run(*args: str) -> dict:
    try:
        p = subprocess.run(args, text=True, capture_output=True, timeout=60)
        return {"command": list(args), "exit_code": p.returncode,
                "stdout": p.stdout[-8000:], "stderr": p.stderr[-8000:]}
    except Exception as exc:
        return {"command": list(args), "error": repr(exc)}

root = Path(subprocess.check_output(
    ["git", "rev-parse", "--show-toplevel"], text=True
).strip())
state = root / ".forge-e2-state"
state.mkdir(exist_ok=True)

report = {
    "schema_version": 1,
    "recorded_at": datetime.now(timezone.utc).isoformat(),
    "root": str(root),
    "platform": platform.platform(),
    "machine": platform.machine(),
    "tools": {name: shutil.which(name) for name in
              ["swift", "xcodebuild", "clang", "git", "python3"]},
    "commands": [
        run("git", "-C", str(root), "status", "--short"),
        run("git", "-C", str(root), "rev-parse", "HEAD"),
        run("git", "-C", str(root), "branch", "--show-current"),
        run("swift", "--version") if shutil.which("swift") else {"missing":"swift"},
        run("xcodebuild", "-version") if shutil.which("xcodebuild") else {"missing":"xcodebuild"},
        run("clang", "--version") if shutil.which("clang") else {"missing":"clang"},
    ],
}
path = state / "doctor.json"
path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
print(json.dumps(report, indent=2))
