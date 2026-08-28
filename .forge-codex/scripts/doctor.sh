#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_DIR="$ROOT/.forge-codex/state"
mkdir -p "$STATE_DIR"
OUT="$STATE_DIR/environment.json"

python3 - "$ROOT" "$OUT" <<'PY'
from __future__ import annotations
import json, os, platform, shutil, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path

root = Path(sys.argv[1])
out = Path(sys.argv[2])
state_path = root / ".forge-codex" / "state" / "run-state.json"
gate_plan_path = root / ".forge-codex" / "plans" / "gates.json"

def command(argv):
    exe = shutil.which(argv[0])
    if not exe:
        return {"available": False, "path": None, "exit_code": 127, "output": ""}
    try:
        p = subprocess.run(argv, cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        return {"available": True, "path": exe, "exit_code": p.returncode, "output": p.stdout[-12000:]}
    except Exception as exc:
        return {"available": True, "path": exe, "exit_code": -1, "output": repr(exc)}

tools = {
    "git": command(["git","--version"]),
    "swift": command(["swift","--version"]),
    "xcodebuild": command(["xcodebuild","-version"]),
    "xcrun": command(["xcrun","--version"]),
    "xctrace": command(["xcrun","xctrace","version"]) if shutil.which("xcrun") else {"available":False},
    "sqlite3": command(["sqlite3","--version"]),
    "bash": command(["bash","--version"]),
    "python3": command(["python3","--version"]),
}
markers = {
    "package_swift": str(root / "Package.swift") if (root / "Package.swift").exists() else None,
    "workspaces": [str(p.relative_to(root)) for p in root.glob("*.xcworkspace")],
    "projects": [str(p.relative_to(root)) for p in root.glob("*.xcodeproj")],
}

execution_state = {
    "available": False,
    "current_work": None,
    "open_issues": [],
    "nonpassing_hard_gates": [],
}
try:
    state = json.loads(state_path.read_text(encoding="utf-8"))
    gate_plan = json.loads(gate_plan_path.read_text(encoding="utf-8"))
    hard_gate_ids = {
        gate["id"]
        for gate in gate_plan.get("gates", [])
        if gate.get("type") in {"hard", "hard_runtime"}
    }
    execution_state = {
        "available": True,
        "run_status": state.get("status"),
        "current_work": state.get("current_work"),
        "repository": state.get("repository", {}),
        "open_issues": [
            {
                "id": issue.get("id"),
                "title": issue.get("title"),
                "status": issue.get("status"),
                "severity": issue.get("severity"),
                "evidence_class": issue.get("evidence_class"),
                "notes": issue.get("notes"),
            }
            for issue in state.get("issues", [])
            if issue.get("status") != "resolved"
        ],
        "nonpassing_hard_gates": [
            {
                "id": gate_id,
                "status": state.get("gates", {}).get(gate_id, {}).get("status", "not_started"),
            }
            for gate_id in sorted(hard_gate_ids)
            if state.get("gates", {}).get(gate_id, {}).get("status") != "passed"
        ],
    }
except (OSError, ValueError, TypeError, KeyError) as exc:
    execution_state["error"] = repr(exc)

payload = {
    "schema_version": 1,
    "captured_at": datetime.now(timezone.utc).isoformat(),
    "platform": platform.platform(),
    "machine": platform.machine(),
    "macos_runtime_capable": platform.system() == "Darwin" and tools["xcodebuild"].get("available", False),
    "repository_root": str(root),
    "tools": tools,
    "project_markers": markers,
    "execution_state": execution_state,
    "environment_keys_present": sorted(k for k in os.environ if k.startswith(("CI","CODEX","XCODE","SWIFT","FORGE"))),
}
tmp = out.with_suffix(".tmp")
tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
os.replace(tmp, out)
print(json.dumps({
    "environment_file": str(out),
    "macos_runtime_capable": payload["macos_runtime_capable"],
    "current_work": execution_state.get("current_work"),
    "open_issues": execution_state.get("open_issues", []),
    "nonpassing_hard_gates": execution_state.get("nonpassing_hard_gates", []),
}))
PY
