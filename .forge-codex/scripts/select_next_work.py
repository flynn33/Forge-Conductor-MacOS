#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, subprocess, sys
from pathlib import Path
from datetime import datetime, timezone

from checkpoint_identity import resolve_checkpoint_identity

def locate_repo(explicit):
    if explicit: return Path(explicit).resolve()
    p=Path.cwd().resolve()
    for c in (p,*p.parents):
        if (c/".forge-codex").is_dir(): return c
    raise SystemExit("repository not found")

parser=argparse.ArgumentParser()
parser.add_argument("--repo")
args=parser.parse_args()
repo=locate_repo(args.repo)
pkg=repo/".forge-codex"
state=json.loads((pkg/"state/run-state.json").read_text())
plan=json.loads((pkg/"plans/phases.json").read_text())
gate_plan=json.loads((pkg/"plans/gates.json").read_text())
mandatory_release_issue_ids={
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
hard_gate_ids={
    gate["id"]
    for gate in gate_plan.get("gates", [])
    if gate.get("type") in {"hard", "hard_runtime"}
}
gate_deferrals={
    "G09": "real_provider_manager_owned_rollover_evidence_required",
    "G10": "p10_e2_native_and_privileged_lifecycle_evidence_required",
    "G11": "owner_deferred_representative_physical_hardware_release_blocker",
    "G12": "all_prior_hard_gates_and_final_release_evidence_required",
}

by_id={p["id"]:p for p in plan["phases"]}
passed={pid for pid,s in state["phases"].items() if s["status"]=="passed"}
running=[pid for pid,s in state["phases"].items() if s["status"]=="running"]
if running:
    chosen=sorted(running, key=lambda p:-by_id[p]["priority"])[0]
    reason="resume_running"
else:
    ready=[]
    for phase in plan["phases"]:
        status=state["phases"][phase["id"]]["status"]
        if status=="passed": continue
        if all(dep in passed for dep in phase["dependencies"]):
            ready.append(phase)
    if not ready:
        chosen=None
        reason="no_ready_phase"
    else:
        ready.sort(key=lambda p:(-p["priority"],p["id"]))
        chosen=ready[0]["id"]
        reason="highest_priority_ready"
open_issues=[i for i in state["issues"] if i.get("status")!="resolved"]
mandatory_release_blockers=[
    i for i in open_issues if i.get("id") in mandatory_release_issue_ids
]
issue_status_by_id={
    issue.get("id"):issue.get("status")
    for issue in state.get("issues",[])
    if issue.get("id")
}
required_open_disclosure_ids={
    issue_id
    for issue_id in mandatory_release_issue_ids
    if issue_status_by_id.get(issue_id)!="resolved"
}
nonpassing_hard_gates=[
    {
        "id": gate_id,
        "status": state.get("gates", {}).get(gate_id, {}).get("status", "not_started"),
        "release_blocking": True,
        "deferral": gate_deferrals.get(gate_id),
    }
    for gate_id in sorted(hard_gate_ids)
    if state.get("gates", {}).get(gate_id, {}).get("status") != "passed"
]
identity=resolve_checkpoint_identity(repo)
completion_authority_current=False
if state.get("status")=="complete":
    try:
        validation=subprocess.run(
            [
                sys.executable,
                str(pkg/"scripts/statectl.py"),
                "--repo",
                str(repo),
                "validate",
            ],
            cwd=repo,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
            check=False,
        )
        completion_authority_current=validation.returncode==0
    except (OSError, subprocess.SubprocessError):
        completion_authority_current=False
disclosures_aligned=all(
    required_id in {issue.get("id") for issue in mandatory_release_blockers}
    for required_id in required_open_disclosure_ids
) and all(
    required_gate in {gate.get("id") for gate in nonpassing_hard_gates}
    for required_gate in {"G09", "G10", "G11", "G12"}
)
print(json.dumps({
    "selected_phase":chosen,
    "reason":reason,
    "phase":by_id.get(chosen),
    "open_issues":open_issues,
    "nonpassing_hard_gates":nonpassing_hard_gates,
    "release_authorized":not mandatory_release_blockers
        and not nonpassing_hard_gates
        and state.get("status") == "complete"
        and completion_authority_current,
    "completion_authority_current":completion_authority_current,
    "mandatory_release_blockers":mandatory_release_blockers,
    "checkpoint_identity":identity,
    "partial_security_pr_policy":{
        "reviewable":identity["github_readback_verified"] and disclosures_aligned,
        "merge_authorized":False,
        "merge_requires_residuals_in_pr_state_doctor_and_selector":True,
        "does_not_close_p10_e2_native_continuity_or_hardware":True,
    },
    "selection_constraints":{
        "p10_e2_native_and_continuity_must_remain_open_without_required_evidence":True,
        "partial_security_pr_must_disclose_residuals_and_deferred_gates":True,
        "simulator_or_current_host_results_do_not_pass_owner_deferred_g11":True,
    },
    "timestamp":datetime.now(timezone.utc).isoformat()
},indent=2))
