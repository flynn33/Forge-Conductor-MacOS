#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path

from integrity import (
    actual_source_manifest,
    atomic_json,
    canonical_sha256,
    load_json,
    safe_repo_path,
    verify_gate_receipt,
)


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify that Forge Conductor is release-ready while remaining unshipped")
    parser.add_argument("--repo", default=".")
    args = parser.parse_args()
    repo = Path(args.repo).resolve()
    state_path = repo / ".forge-qwen-state/run-state.json"
    state = load_json(state_path)
    gates = load_json(repo / ".forge-qwen-remediation/plans/gates.json")["gates"]
    work = load_json(repo / ".forge-qwen-remediation/plans/work-packages.json")["work_packages"]
    issues = load_json(repo / ".forge-qwen-state/issues.json")["issues"]
    errors: list[str] = []
    final_manifest = actual_source_manifest(repo)

    if state.get("source_manifest_sha256") != final_manifest:
        errors.append("run state source manifest is stale")
    if state.get("current_source_manifest_sha256") != final_manifest:
        errors.append("run state current source manifest is stale")

    for gate in gates:
        if not gate.get("mandatory", True):
            continue
        gate_id = gate["id"]
        status = state.get("gate_status", {}).get(gate_id)
        relative = state.get("gate_receipts", {}).get(gate_id)
        if status != "passed":
            errors.append(f"mandatory gate {gate_id} is {status}")
            continue
        if not relative:
            errors.append(f"mandatory gate {gate_id} has no immutable receipt")
            continue
        try:
            receipt_path = safe_repo_path(repo, relative)
            if not receipt_path.is_file():
                errors.append(f"mandatory gate {gate_id} receipt is missing")
                continue
            receipt = load_json(receipt_path)
            for item in verify_gate_receipt(
                repo,
                receipt,
                expected_gate_id=gate_id,
                expected_source_manifest=final_manifest,
            ):
                errors.append(f"{gate_id}: {item}")
        except Exception as exc:
            errors.append(f"{gate_id}: invalid receipt: {exc}")

    issue_ids = {item["id"] for item in issues}
    open_findings = set(state.get("open_findings", []))
    if open_findings:
        errors.append(f"open findings remain: {sorted(open_findings)}")
    finding_status = state.get("finding_status", {})
    for finding_id in sorted(issue_ids):
        if finding_status.get(finding_id) != "resolved":
            errors.append(f"finding {finding_id} is not resolved")
            continue
        closure_path = repo / ".forge-qwen-state/finding-closures" / f"{finding_id}.json"
        if not closure_path.is_file():
            errors.append(f"finding {finding_id} has no immutable closure receipt")
            continue
        closure = load_json(closure_path)
        if closure.get("finding_id") != finding_id or closure.get("status") != "resolved":
            errors.append(f"finding {finding_id} closure identity/status is invalid")
        if closure.get("source_manifest_sha256") != final_manifest:
            errors.append(f"finding {finding_id} closure is stale for the final source")
        if closure.get("closure_sha256") != canonical_sha256(closure, "closure_sha256"):
            errors.append(f"finding {finding_id} closure checksum mismatch")
        for relative in closure.get("evidence_receipts", []):
            try:
                if not safe_repo_path(repo, relative).is_file():
                    errors.append(f"finding {finding_id} evidence is missing: {relative}")
            except Exception as exc:
                errors.append(f"finding {finding_id} evidence path invalid: {exc}")

    required_work = {item["id"] for item in work}
    completed_work = set(state.get("completed_work_packages", []))
    incomplete = sorted(required_work - completed_work)
    if incomplete:
        errors.append(f"incomplete work packages: {incomplete}")
    for work_id in required_work:
        if state.get("work_package_status", {}).get(work_id) != "completed":
            errors.append(f"work package status is not completed: {work_id}")

    if state.get("shipped") is not False:
        errors.append("shipped must be false")

    attestation_path = repo / ".forge-qwen-state/release-readiness.json"
    if not attestation_path.is_file():
        errors.append("release-readiness.json is missing")
    else:
        attestation = load_json(attestation_path)
        if attestation.get("ready_to_ship") is not True or attestation.get("shipped") is not False:
            errors.append("release attestation readiness flags are invalid")
        if attestation.get("source_manifest_sha256") != final_manifest:
            errors.append("release attestation is stale for the final source")
        if attestation.get("source_archive_sha256") != state.get("source_archive_sha256"):
            errors.append("release attestation source archive hash mismatch")
        if attestation.get("open_findings") != []:
            errors.append("release attestation contains open findings")
        if attestation.get("attestation_sha256") != canonical_sha256(attestation, "attestation_sha256"):
            errors.append("release attestation checksum mismatch")
        child_gates = {gate["id"] for gate in gates if gate.get("mandatory", True) and gate["id"] != "G20"}
        if set(attestation.get("mandatory_gate_results", {})) != child_gates:
            errors.append("release attestation does not enumerate exactly G00-G19 mandatory child gates")
        elif any(value != "passed" for value in attestation["mandatory_gate_results"].values()):
            errors.append("release attestation contains a nonpassing child gate")
        if set(attestation.get("mandatory_gate_receipts", {})) != child_gates:
            errors.append("release attestation receipt index is incomplete")
        candidate_relative = attestation.get("release_candidate_path")
        if not isinstance(candidate_relative, str):
            errors.append("release candidate path is missing")
        else:
            try:
                candidate = safe_repo_path(repo, candidate_relative)
                if not candidate.is_file():
                    errors.append("release candidate file is missing")
                elif hashlib.sha256(candidate.read_bytes()).hexdigest() != attestation.get("release_candidate_sha256"):
                    errors.append("release candidate hash mismatch")
            except Exception as exc:
                errors.append(f"release candidate path is invalid: {exc}")

    no_ship = subprocess.run(
        ["python3", str(repo / ".forge-qwen-remediation/scripts/verify_no_ship.py"), "--repo", str(repo)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if no_ship.returncode != 0:
        errors.append("no-ship verification failed: " + no_ship.stdout.strip()[:1000])

    ready = not errors
    report = {
        "ready_to_ship": ready,
        "shipped": False,
        "source_manifest_sha256": final_manifest,
        "errors": errors,
    }
    completion_path = repo / ".forge-qwen-state/completion-report.json"
    atomic_json(completion_path, report)
    if ready:
        state["ready_to_ship"] = True
        state["status"] = "ready"
        state["source_manifest_sha256"] = final_manifest
        state["current_source_manifest_sha256"] = final_manifest
        atomic_json(state_path, state)
    print(json.dumps(report, indent=2))
    return 0 if ready else 1


if __name__ == "__main__":
    raise SystemExit(main())
