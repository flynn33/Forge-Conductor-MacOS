#!/usr/bin/env python3
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
from pathlib import Path
from typing import Any

from source_manifest import manifest


def canonical_sha256(value: dict[str, Any], checksum_field: str) -> str:
    payload = {key: item for key, item in value.items() if key != checksum_field}
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def safe_repo_path(repo: Path, relative: str) -> Path:
    candidate = Path(relative)
    if candidate.is_absolute() or ".." in candidate.parts:
        raise ValueError(f"unsafe repository-relative path: {relative}")
    resolved = (repo / candidate).resolve()
    try:
        resolved.relative_to(repo.resolve())
    except ValueError as exc:
        raise ValueError(f"path escapes repository: {relative}") from exc
    return resolved


def verify_artifacts(repo: Path, artifacts: list[dict[str, Any]]) -> list[str]:
    errors: list[str] = []
    for index, artifact in enumerate(artifacts):
        try:
            path = safe_repo_path(repo, str(artifact["path"]))
            if not path.is_file():
                errors.append(f"artifact {index} missing: {artifact.get('path')}")
                continue
            data = path.read_bytes()
            if int(artifact.get("bytes", -1)) != len(data):
                errors.append(f"artifact {index} byte count mismatch: {artifact.get('path')}")
            digest = hashlib.sha256(data).hexdigest()
            if artifact.get("sha256") != digest:
                errors.append(f"artifact {index} hash mismatch: {artifact.get('path')}")
        except Exception as exc:  # validation must report every bad artifact
            errors.append(f"artifact {index} invalid: {exc}")
    return errors


def gate_map(repo: Path) -> dict[str, dict[str, Any]]:
    gates = load_json(repo / ".forge-qwen-remediation/plans/gates.json")["gates"]
    return {str(gate["id"]): gate for gate in gates}


def work_package_map(repo: Path) -> dict[str, dict[str, Any]]:
    work = load_json(repo / ".forge-qwen-remediation/plans/work-packages.json")["work_packages"]
    return {str(item["id"]): item for item in work}


def actual_source_manifest(repo: Path) -> str:
    return str(manifest(repo)["manifest_sha256"])


def verify_gate_receipt(
    repo: Path,
    receipt: dict[str, Any],
    *,
    expected_gate_id: str | None = None,
    expected_source_manifest: str | None = None,
) -> list[str]:
    errors: list[str] = []
    required = {
        "schema_version",
        "execution_id",
        "gate_id",
        "work_package",
        "validator_id",
        "validator_version",
        "project_id",
        "project_generation",
        "source_manifest_before",
        "source_manifest_after",
        "started_at",
        "ended_at",
        "passed",
        "status",
        "artifacts",
        "receipt_sha256",
    }
    missing = sorted(required - set(receipt))
    if missing:
        errors.append(f"gate receipt missing fields: {missing}")
        return errors
    if receipt.get("schema_version") != 1:
        errors.append("gate receipt schema_version must be 1")
    gate_id = str(receipt.get("gate_id"))
    if expected_gate_id is not None and gate_id != expected_gate_id:
        errors.append(f"gate receipt is for {gate_id}, expected {expected_gate_id}")
    definition = gate_map(repo).get(gate_id)
    if definition is None:
        errors.append(f"unknown gate: {gate_id}")
    else:
        if receipt.get("work_package") != definition.get("work_package"):
            errors.append("gate receipt work package does not match gate registry")
        if receipt.get("validator_id") != definition.get("validator_id"):
            errors.append("gate receipt validator_id does not match gate registry")
        if receipt.get("validator_version") != definition.get("validator_version"):
            errors.append("gate receipt validator_version does not match gate registry")
    if receipt.get("passed") is not True or receipt.get("status") != "passed":
        errors.append("gate receipt is not a passing result")
    if not isinstance(receipt.get("project_id"), str) or not receipt["project_id"]:
        errors.append("gate receipt project_id is missing")
    if not isinstance(receipt.get("project_generation"), int) or receipt["project_generation"] < 1:
        errors.append("gate receipt project_generation is invalid")
    before = receipt.get("source_manifest_before")
    after = receipt.get("source_manifest_after")
    if before != after:
        errors.append("gate validator changed the source manifest while executing")
    if expected_source_manifest is not None and after != expected_source_manifest:
        errors.append("gate receipt is stale for the current source manifest")
    if not receipt.get("command") and not receipt.get("native_action"):
        errors.append("gate receipt must describe a command or native action")
    expected_hash = canonical_sha256(receipt, "receipt_sha256")
    if receipt.get("receipt_sha256") != expected_hash:
        errors.append("gate receipt checksum mismatch")
    artifacts = receipt.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        errors.append("gate receipt must contain at least one immutable artifact")
    else:
        errors.extend(verify_artifacts(repo, artifacts))
    for field in ("started_at", "ended_at"):
        try:
            dt.datetime.fromisoformat(str(receipt[field]).replace("Z", "+00:00"))
        except Exception:
            errors.append(f"gate receipt {field} is not an ISO-8601 timestamp")
    return errors


def append_event(repo: Path, kind: str, payload: dict[str, Any]) -> dict[str, Any]:
    state_path = repo / ".forge-qwen-state/run-state.json"
    state = load_json(state_path)
    record: dict[str, Any] = {
        "schema_version": 1,
        "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
        "kind": kind,
        "payload": payload,
        "previous_hash": state.get("last_event_hash"),
    }
    record["event_hash"] = canonical_sha256(record, "event_hash")
    events_path = repo / ".forge-qwen-state/events.jsonl"
    events_path.parent.mkdir(parents=True, exist_ok=True)
    with events_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True, ensure_ascii=False) + "\n")
    state["last_event_hash"] = record["event_hash"]
    state["updated_at"] = record["timestamp"]
    state["status"] = "in_progress"
    atomic_json(state_path, state)
    return record
