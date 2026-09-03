#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path

from integrity import append_event, atomic_json, load_json, work_package_map


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("show")
    select = sub.add_parser("select")
    select.add_argument("work_package")
    complete = sub.add_parser("complete")
    complete.add_argument("work_package")
    gate = sub.add_parser("gate")
    gate.add_argument("gate_id")
    gate.add_argument("status", choices=["pending", "running", "failed", "blocked_environment"])
    gate.add_argument("--reason")
    handoff = sub.add_parser("handoff")
    handoff.add_argument("--summary", required=True)
    handoff.add_argument("--next", required=True)
    args = parser.parse_args()

    repo = Path(args.repo).resolve()
    state_path = repo / ".forge-qwen-state/run-state.json"
    state = load_json(state_path)
    work = work_package_map(repo)
    gates = {
        item["id"]: item
        for item in load_json(repo / ".forge-qwen-remediation/plans/gates.json")["gates"]
    }

    if args.command == "show":
        print(json.dumps(state, indent=2))
        return 0

    if args.command == "select":
        work_id = args.work_package
        if work_id not in work:
            raise SystemExit(f"unknown work package: {work_id}")
        completed = set(state.get("completed_work_packages", []))
        missing = [item for item in work[work_id].get("depends_on", []) if item not in completed]
        if missing:
            raise SystemExit(f"work package {work_id} is not ready; incomplete dependencies: {missing}")
        current = state.get("current_work_package")
        if current and current != work_id and current not in completed:
            raise SystemExit(f"finish or explicitly block current work package {current} before selecting {work_id}")
        state["current_work_package"] = work_id
        state.setdefault("work_package_status", {})[work_id] = "selected"
        atomic_json(state_path, state)
        append_event(repo, "work_selected", {"work_package": work_id})

    elif args.command == "complete":
        work_id = args.work_package
        if work_id not in work:
            raise SystemExit(f"unknown work package: {work_id}")
        required_gates = work[work_id].get("gates", [])
        not_passed = [gate_id for gate_id in required_gates if state.get("gate_status", {}).get(gate_id) != "passed"]
        if not_passed:
            raise SystemExit(f"cannot complete {work_id}; required gates not passed: {not_passed}")
        if work_id not in state["completed_work_packages"]:
            state["completed_work_packages"].append(work_id)
        state.setdefault("work_package_status", {})[work_id] = "completed"
        if state.get("current_work_package") == work_id:
            state["current_work_package"] = None
        atomic_json(state_path, state)
        append_event(repo, "work_completed", {"work_package": work_id, "gate_ids": required_gates})

    elif args.command == "gate":
        gate_id = args.gate_id
        if gate_id not in gates:
            raise SystemExit(f"unknown gate: {gate_id}")
        # Passing is intentionally impossible here. Only accept_gate_result.py may pass a gate.
        state.setdefault("gate_status", {})[gate_id] = args.status
        if args.status != "pending":
            state["ready_to_ship"] = False
        atomic_json(state_path, state)
        append_event(repo, "gate_status", {
            "gate_id": gate_id,
            "status": args.status,
            "reason": args.reason,
        })

    elif args.command == "handoff":
        payload = {
            "schema_version": 1,
            "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
            "current_work_package": state.get("current_work_package"),
            "summary": args.summary,
            "next_action": args.next,
            "source_manifest_sha256": state.get("current_source_manifest_sha256", state["source_manifest_sha256"]),
            "open_findings": state.get("open_findings", []),
            "gate_status": state.get("gate_status", {}),
            "ready_to_ship": False,
            "shipped": False,
        }
        atomic_json(repo / ".forge-qwen-state/current-handoff.json", payload)
        append_event(repo, "handoff", payload)

    print(json.dumps(load_json(state_path), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
