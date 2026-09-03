#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

from integrity import actual_source_manifest, append_event, atomic_json, load_json, verify_gate_receipt


def main() -> int:
    parser = argparse.ArgumentParser(description="Accept an immutable result from a registered gate validator")
    parser.add_argument("--repo", default=".")
    parser.add_argument("--receipt", required=True)
    args = parser.parse_args()

    repo = Path(args.repo).resolve()
    source_path = Path(args.receipt).resolve()
    receipt = load_json(source_path)
    current_manifest = actual_source_manifest(repo)
    errors = verify_gate_receipt(repo, receipt, expected_source_manifest=current_manifest)
    if errors:
        print(json.dumps({"accepted": False, "errors": errors}, indent=2))
        return 1

    gate_id = str(receipt["gate_id"])
    execution_id = str(receipt["execution_id"])
    destination = repo / ".forge-qwen-state/gate-results" / gate_id / f"{execution_id}.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if destination.read_bytes() != source_path.read_bytes():
            print(json.dumps({"accepted": False, "errors": ["execution_id already exists with different content"]}, indent=2))
            return 1
    else:
        shutil.copy2(source_path, destination)
        destination.chmod(0o444)

    state_path = repo / ".forge-qwen-state/run-state.json"
    state = load_json(state_path)
    state.setdefault("gate_receipts", {})[gate_id] = destination.relative_to(repo).as_posix()
    state.setdefault("gate_status", {})[gate_id] = "passed"
    state["source_manifest_sha256"] = current_manifest
    state["current_source_manifest_sha256"] = current_manifest
    state["ready_to_ship"] = False
    atomic_json(state_path, state)
    append_event(repo, "gate_result_accepted", {
        "gate_id": gate_id,
        "execution_id": execution_id,
        "receipt_sha256": receipt["receipt_sha256"],
        "source_manifest_sha256": current_manifest,
    })
    print(json.dumps({
        "accepted": True,
        "gate_id": gate_id,
        "receipt": destination.relative_to(repo).as_posix(),
        "source_manifest_sha256": current_manifest,
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
