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
sys.path.insert(0, str(root / ".forge-codex" / "scripts"))
from checkpoint_identity import resolve_checkpoint_identity

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
mandatory_release_issue_ids = {
    "FC-FILESYSTEM-PATH-TOCTOU-001",
    "FC-UI-QUALIFICATION-001",
    "FC-SHELL-COMPAT-QUALIFICATION-001",
    "FC-AUTONOMOUS-CONTINUITY-E2E-001",
    "FC-HARDWARE-QUALIFICATION-001",
    "FC-PROJECT-BOOTSTRAP-AUTHORITY-001",
    "FC-CONTROL-STATE-PATH-AUTHORITY-001",
    "FC-PROJECT-ROOT-SETTINGS-001",
    "FC-PRIVILEGED-SERVICE-LIFECYCLE-001",
    "FC-PRIVILEGED-CALLER-IDENTITY-001",
}
gate_deferrals = {
    "G09": "real_provider_manager_owned_rollover_evidence_required",
    "G10": "p10_e2_native_and_privileged_lifecycle_evidence_required",
    "G11": "owner_deferred_representative_physical_hardware_release_blocker",
    "G12": "all_prior_hard_gates_and_final_release_evidence_required",
}
try:
    state = json.loads(state_path.read_text(encoding="utf-8"))
    gate_plan = json.loads(gate_plan_path.read_text(encoding="utf-8"))
    hard_gate_ids = {
        gate["id"]
        for gate in gate_plan.get("gates", [])
        if gate.get("type") in {"hard", "hard_runtime"}
    }
    open_issues = [
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
    ]
    nonpassing_hard_gates = [
        {
            "id": gate_id,
            "status": state.get("gates", {}).get(gate_id, {}).get("status", "not_started"),
            "release_blocking": True,
            "deferral": gate_deferrals.get(gate_id),
        }
        for gate_id in sorted(hard_gate_ids)
        if state.get("gates", {}).get(gate_id, {}).get("status") != "passed"
    ]
    mandatory_release_blockers = [
        issue for issue in open_issues if issue.get("id") in mandatory_release_issue_ids
    ]
    issue_status_by_id = {
        issue.get("id"): issue.get("status")
        for issue in state.get("issues", [])
        if issue.get("id")
    }
    required_open_disclosure_ids = {
        issue_id
        for issue_id in mandatory_release_issue_ids
        if issue_status_by_id.get(issue_id) != "resolved"
    }
    identity = resolve_checkpoint_identity(root)
    disclosures_aligned = all(
        required_id in {issue.get("id") for issue in mandatory_release_blockers}
        for required_id in required_open_disclosure_ids
    ) and all(
        required_gate in {gate.get("id") for gate in nonpassing_hard_gates}
        for required_gate in {"G09", "G10", "G11", "G12"}
    )
    execution_state = {
        "available": True,
        "run_status": state.get("status"),
        "current_work": state.get("current_work"),
        "repository": state.get("repository", {}),
        "open_issues": open_issues,
        "nonpassing_hard_gates": nonpassing_hard_gates,
        "release_authorized": state.get("status") == "complete"
            and not mandatory_release_blockers
            and not nonpassing_hard_gates,
        "mandatory_release_blockers": mandatory_release_blockers,
        "checkpoint_identity": identity,
        "partial_security_pr_policy": {
            "reviewable": identity["github_readback_verified"] and disclosures_aligned,
            "merge_authorized": False,
            "merge_requires_residuals_in_pr_state_doctor_and_selector": True,
            "does_not_close_p10_e2_native_continuity_or_hardware": True,
            "simulator_or_current_host_results_do_not_pass_owner_deferred_g11": True,
        },
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
    "release_authorized": execution_state.get("release_authorized", False),
    "mandatory_release_blockers": execution_state.get("mandatory_release_blockers", []),
    "checkpoint_identity": execution_state.get("checkpoint_identity", {}),
    "partial_security_pr_policy": execution_state.get("partial_security_pr_policy", {}),
}))
PY
