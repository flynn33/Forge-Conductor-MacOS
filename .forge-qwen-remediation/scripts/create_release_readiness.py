#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import platform
import subprocess
from pathlib import Path

from integrity import actual_source_manifest, atomic_json, canonical_sha256, load_json, safe_repo_path, verify_gate_receipt


def command_output(arguments: list[str]) -> str | None:
    try:
        result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30, check=False)
        return result.stdout.strip()[:4096] if result.returncode == 0 else None
    except Exception:
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description="Create a local release-readiness attestation without shipping")
    parser.add_argument("--repo", default=".")
    parser.add_argument("--release-candidate", required=True)
    args = parser.parse_args()
    repo = Path(args.repo).resolve()
    state = load_json(repo / ".forge-qwen-state/run-state.json")
    gates = load_json(repo / ".forge-qwen-remediation/plans/gates.json")["gates"]
    errors: list[str] = []
    source_manifest = actual_source_manifest(repo)

    gate_results: dict[str, str] = {}
    gate_receipts: dict[str, str] = {}
    for gate in gates:
        gate_id = gate["id"]
        if gate_id == "G20" or not gate.get("mandatory", True):
            continue
        relative = state.get("gate_receipts", {}).get(gate_id)
        if state.get("gate_status", {}).get(gate_id) != "passed" or not relative:
            errors.append(f"mandatory child gate {gate_id} has no accepted receipt")
            continue
        try:
            receipt_path = safe_repo_path(repo, relative)
            receipt = load_json(receipt_path)
            receipt_errors = verify_gate_receipt(repo, receipt, expected_gate_id=gate_id, expected_source_manifest=source_manifest)
            errors.extend(f"{gate_id}: {item}" for item in receipt_errors)
            if not receipt_errors:
                gate_results[gate_id] = "passed"
                gate_receipts[gate_id] = relative
        except Exception as exc:
            errors.append(f"{gate_id}: {exc}")

    if state.get("open_findings"):
        errors.append(f"open findings remain: {state['open_findings']}")
    release_candidate = Path(args.release_candidate).resolve()
    try:
        release_relative = release_candidate.relative_to(repo).as_posix()
    except ValueError:
        errors.append("release candidate must be inside the repository state directory")
        release_relative = str(release_candidate)
    if not release_candidate.is_file():
        errors.append("release candidate file does not exist")

    if errors:
        print(json.dumps({"created": False, "errors": errors}, indent=2))
        return 1

    release_hash = hashlib.sha256(release_candidate.read_bytes()).hexdigest()
    attestation = {
        "schema_version": 1,
        "source_archive_sha256": state["source_archive_sha256"],
        "source_manifest_sha256": source_manifest,
        "git_commit": command_output(["git", "-C", str(repo), "rev-parse", "HEAD"]),
        "git_tree": command_output(["git", "-C", str(repo), "rev-parse", "HEAD^{tree}"]),
        "toolchain": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "swift": command_output(["swift", "--version"]),
            "xcode": command_output(["xcodebuild", "-version"]),
        },
        "release_candidate_path": release_relative,
        "release_candidate_sha256": release_hash,
        "mandatory_gate_results": gate_results,
        "mandatory_gate_receipts": gate_receipts,
        "open_findings": [],
        "ready_to_ship": True,
        "shipped": False,
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "attestation_sha256": "",
    }
    attestation["attestation_sha256"] = canonical_sha256(attestation, "attestation_sha256")
    path = repo / ".forge-qwen-state/release-readiness.json"
    atomic_json(path, attestation)
    print(json.dumps({"created": True, "attestation": path.relative_to(repo).as_posix(), "shipped": False}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
