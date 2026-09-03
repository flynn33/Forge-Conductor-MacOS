#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

AUTHORITATIVE_KEYS = (
    "status",
    "ready_to_ship",
    "shipped",
    "current_work_package",
    "completed_work_packages",
    "blocked_work_packages",
    "work_package_status",
    "gate_status",
    "gate_receipts",
    "finding_status",
    "open_findings",
    "current_source_manifest_sha256",
)


def normalize(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: normalize(value[key]) for key in sorted(value)}
    if isinstance(value, list):
        return [normalize(item) for item in value]
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    repo = Path(args.repo).resolve()
    state_path = repo / ".forge-qwen-state/run-state.json"
    state = json.loads(state_path.read_text(encoding="utf-8"))
    authoritative = {
        key: normalize(state.get(key))
        for key in AUTHORITATIVE_KEYS
    }

    evidence_ids: list[str] = []
    evidence_root = repo / ".forge-qwen-state/evidence"
    if evidence_root.is_dir():
        evidence_ids = sorted(
            path.relative_to(evidence_root).as_posix()
            for path in evidence_root.rglob("*")
            if path.is_file() and not path.name.startswith(".")
        )
    authoritative["evidence_files"] = evidence_ids

    closures = repo / ".forge-qwen-state/finding-closures"
    authoritative["finding_closure_files"] = sorted(
        path.relative_to(closures).as_posix()
        for path in closures.rglob("*")
        if path.is_file()
    ) if closures.is_dir() else []

    encoded = json.dumps(
        authoritative,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    digest = hashlib.sha256(encoded).hexdigest()
    if args.json:
        print(json.dumps({
            "schema_version": 1,
            "sha256": digest,
            "authoritative": authoritative,
        }, indent=2))
    else:
        print(digest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
