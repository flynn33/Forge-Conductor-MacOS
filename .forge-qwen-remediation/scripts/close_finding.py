#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

from integrity import actual_source_manifest, append_event, atomic_json, canonical_sha256, gate_map, load_json, safe_repo_path, work_package_map


def main() -> int:
    parser = argparse.ArgumentParser(description="Accept an immutable evidence-backed audit finding closure")
    parser.add_argument("--repo", default=".")
    parser.add_argument("--closure", required=True)
    args = parser.parse_args()

    repo = Path(args.repo).resolve()
    source_path = Path(args.closure).resolve()
    closure = load_json(source_path)
    issues = {item["id"]: item for item in load_json(repo / ".forge-qwen-state/issues.json")["issues"]}
    mapping = load_json(repo / ".forge-qwen-remediation/plans/finding-to-work-package.json")["mapping"]
    work = work_package_map(repo)
    gates = gate_map(repo)
    errors: list[str] = []

    required = {
        "schema_version", "finding_id", "status", "summary", "source_manifest_sha256",
        "work_packages", "gate_ids", "evidence_receipts", "residual_risk", "closure_sha256",
    }
    missing = sorted(required - set(closure))
    if missing:
        errors.append(f"closure missing fields: {missing}")
    finding_id = str(closure.get("finding_id", ""))
    issue = issues.get(finding_id)
    if issue is None:
        errors.append(f"unknown finding: {finding_id}")
    if closure.get("schema_version") != 1 or closure.get("status") != "resolved":
        errors.append("finding closure must be schema 1 with status resolved")
    current_manifest = actual_source_manifest(repo)
    if closure.get("source_manifest_sha256") != current_manifest:
        errors.append("finding closure is stale for the current source manifest")
    expected_work = set(mapping.get(finding_id, []))
    supplied_work = set(closure.get("work_packages", []))
    if not expected_work.issubset(supplied_work):
        errors.append(f"finding closure omits mapped work packages: {sorted(expected_work - supplied_work)}")
    expected_gates = {gate_id for work_id in expected_work for gate_id in work[work_id].get("gates", [])}
    supplied_gates = set(closure.get("gate_ids", []))
    if not expected_gates.issubset(supplied_gates):
        errors.append(f"finding closure omits required gates: {sorted(expected_gates - supplied_gates)}")
    state = load_json(repo / ".forge-qwen-state/run-state.json")
    for gate_id in supplied_gates:
        if gate_id not in gates:
            errors.append(f"finding closure references unknown gate {gate_id}")
        elif state.get("gate_status", {}).get(gate_id) != "passed":
            errors.append(f"finding closure references nonpassing gate {gate_id}")
    evidence = closure.get("evidence_receipts", [])
    if not isinstance(evidence, list) or not evidence:
        errors.append("finding closure requires evidence receipt paths")
    else:
        for relative in evidence:
            try:
                path = safe_repo_path(repo, str(relative))
                if not path.is_file():
                    errors.append(f"finding evidence missing: {relative}")
            except Exception as exc:
                errors.append(str(exc))
    residual = closure.get("residual_risk")
    if issue and issue.get("severity") in {"Critical", "High"} and residual != "none":
        errors.append("Critical and High findings require residual_risk exactly 'none'")
    if closure.get("closure_sha256") != canonical_sha256(closure, "closure_sha256"):
        errors.append("finding closure checksum mismatch")

    if errors:
        print(json.dumps({"accepted": False, "errors": errors}, indent=2))
        return 1

    destination = repo / ".forge-qwen-state/finding-closures" / f"{finding_id}.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() and destination.read_bytes() != source_path.read_bytes():
        print(json.dumps({"accepted": False, "errors": ["finding already has a different immutable closure"]}, indent=2))
        return 1
    if not destination.exists():
        shutil.copy2(source_path, destination)
        destination.chmod(0o444)

    state.setdefault("finding_status", {})[finding_id] = "resolved"
    state["open_findings"] = [value for value in state.get("open_findings", []) if value != finding_id]
    state["ready_to_ship"] = False
    atomic_json(repo / ".forge-qwen-state/run-state.json", state)
    append_event(repo, "finding_closed", {
        "finding_id": finding_id,
        "closure_sha256": closure["closure_sha256"],
        "source_manifest_sha256": current_manifest,
    })
    print(json.dumps({"accepted": True, "finding_id": finding_id, "closure": destination.relative_to(repo).as_posix()}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
