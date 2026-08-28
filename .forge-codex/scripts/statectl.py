#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import sys
import tempfile
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1

def now() -> str:
    return datetime.now(timezone.utc).isoformat()

def locate_repo(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit).expanduser().resolve()
    current = Path.cwd().resolve()
    for candidate in (current, *current.parents):
        if (candidate / ".forge-codex").is_dir():
            return candidate
    raise SystemExit("Could not locate repository containing .forge-codex; pass --repo")

def paths(repo: Path) -> tuple[Path, Path, Path, Path]:
    package = repo / ".forge-codex"
    state_dir = package / "state"
    return package, state_dir / "run-state.json", state_dir / "events.jsonl", state_dir / ".state.lock"

@contextmanager
def locked(lock_path: Path):
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)

def atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(name):
            os.unlink(name)

def read_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)

def repository_state(repo: Path) -> dict[str, Any]:
    import subprocess
    def run(*args: str) -> str | None:
        try:
            p = subprocess.run(args, cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10)
            return p.stdout.strip() if p.returncode == 0 else None
        except Exception:
            return None
    status = run("git", "status", "--porcelain=v1") if (repo / ".git").exists() else None
    return {
        "root": str(repo),
        "branch": run("git", "branch", "--show-current"),
        "commit": run("git", "rev-parse", "HEAD"),
        "dirty": bool(status),
    }

def append_event(events_path: Path, state: dict[str, Any], event_type: str, payload: dict[str, Any]) -> dict[str, Any]:
    previous_hash = None
    if events_path.exists():
        try:
            last = events_path.read_text(encoding="utf-8").splitlines()[-1]
            previous_hash = json.loads(last).get("event_hash")
        except Exception:
            previous_hash = "unreadable"
    sequence = int(state.get("last_event_sequence", 0)) + 1
    event = {
        "schema_version": SCHEMA_VERSION,
        "sequence": sequence,
        "event_id": str(uuid.uuid4()),
        "timestamp": now(),
        "type": event_type,
        "payload": payload,
        "previous_hash": previous_hash,
    }
    canonical = json.dumps(event, sort_keys=True, separators=(",", ":")).encode()
    event["event_hash"] = hashlib.sha256(canonical).hexdigest()
    events_path.parent.mkdir(parents=True, exist_ok=True)
    with events_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    state["last_event_sequence"] = sequence
    return event

def initial_state(repo: Path, package: Path) -> dict[str, Any]:
    phase_plan = read_json(package / "plans" / "phases.json")
    gate_plan = read_json(package / "plans" / "gates.json")
    timestamp = now()
    return {
        "schema_version": SCHEMA_VERSION,
        "run_id": str(uuid.uuid4()),
        "status": "active",
        "created_at": timestamp,
        "updated_at": timestamp,
        "repository": repository_state(repo),
        "phases": {p["id"]: {"status": "not_started", "attempts": 0, "last_error": None, "updated_at": None} for p in phase_plan["phases"]},
        "gates": {g["id"]: {"status": "not_started", "evidence_ids": [], "evaluator": None, "updated_at": None} for g in gate_plan["gates"]},
        "issues": [],
        "attempts": [],
        "evidence": [],
        "decisions": [],
        "handoffs": [],
        "current_work": None,
        "last_event_sequence": 0,
    }

def require_state(state_path: Path) -> dict[str, Any]:
    if not state_path.exists():
        raise SystemExit("Run state is absent; execute statectl.py init")
    return read_json(state_path)

def mutate(repo: Path, event_type: str, payload: dict[str, Any], fn) -> dict[str, Any]:
    package, state_path, events_path, lock_path = paths(repo)
    with locked(lock_path):
        state = require_state(state_path)
        fn(state)
        state["updated_at"] = now()
        state["repository"] = repository_state(repo)
        append_event(events_path, state, event_type, payload)
        atomic_json(state_path, state)
        return state

def cmd_init(args) -> int:
    repo = locate_repo(args.repo)
    package, state_path, events_path, lock_path = paths(repo)
    with locked(lock_path):
        if state_path.exists():
            state = read_json(state_path)
            print(json.dumps({"state": str(state_path), "run_id": state["run_id"], "status": state["status"]}, indent=2))
            return 0
        state = initial_state(repo, package)
        append_event(events_path, state, "run_initialized", {"repository": str(repo)})
        atomic_json(state_path, state)
    print(json.dumps({"state": str(state_path), "run_id": state["run_id"], "status": state["status"]}, indent=2))
    return 0

def cmd_show(args) -> int:
    repo = locate_repo(args.repo)
    _, state_path, _, _ = paths(repo)
    state = require_state(state_path)
    if args.compact:
        payload = {
            "run_id": state["run_id"],
            "status": state["status"],
            "current_work": state.get("current_work"),
            "phases": {k:v["status"] for k,v in state["phases"].items()},
            "gates": {k:v["status"] for k,v in state["gates"].items()},
            "open_issues": [i["id"] for i in state["issues"] if i.get("status") != "resolved"],
        }
    else:
        payload = state
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0

def cmd_event(args) -> int:
    repo = locate_repo(args.repo)
    try:
        payload = json.loads(args.payload)
        if not isinstance(payload, dict):
            raise ValueError
    except ValueError:
        raise SystemExit("--payload must be a JSON object")
    mutate(repo, args.type, payload, lambda state: None)
    return 0

def cmd_phase(args) -> int:
    repo = locate_repo(args.repo)
    allowed = {"not_started","ready","running","passed","failed","blocked_dependency","blocked_environment","retry_scheduled"}
    if args.status not in allowed:
        raise SystemExit(f"Invalid phase status: {args.status}")
    def apply(state):
        if args.phase not in state["phases"]:
            raise SystemExit(f"Unknown phase: {args.phase}")
        item = state["phases"][args.phase]
        if args.status == "running" and item["status"] != "running":
            item["attempts"] = int(item.get("attempts", 0)) + 1
        item["status"] = args.status
        item["last_error"] = args.error
        item["updated_at"] = now()
        state["current_work"] = args.phase if args.status == "running" else (None if state.get("current_work") == args.phase else state.get("current_work"))
    mutate(repo, "phase_status", {"phase":args.phase,"status":args.status,"error":args.error}, apply)
    return 0

def cmd_gate(args) -> int:
    repo = locate_repo(args.repo)
    allowed = {"not_started","running","passed","failed","blocked_dependency","blocked_environment","retry_scheduled"}
    if args.status not in allowed:
        raise SystemExit(f"Invalid gate status: {args.status}")
    evidence_ids = args.evidence or []
    def apply(state):
        if args.gate not in state["gates"]:
            raise SystemExit(f"Unknown gate: {args.gate}")
        item = state["gates"][args.gate]
        item["status"] = args.status
        item["evidence_ids"] = sorted(set(item.get("evidence_ids", []) + evidence_ids))
        item["evaluator"] = args.evaluator
        item["updated_at"] = now()
        state["evidence"] = sorted(set(state.get("evidence", []) + evidence_ids))
    mutate(repo, "gate_status", {"gate":args.gate,"status":args.status,"evidence":evidence_ids,"evaluator":args.evaluator}, apply)
    return 0

def cmd_attempt(args) -> int:
    repo = locate_repo(args.repo)
    allowed = {"progress","no_progress","transient_failure","blocked","success"}
    if args.outcome not in allowed:
        raise SystemExit(f"Invalid outcome: {args.outcome}")
    def apply(state):
        prior = [a for a in state["attempts"] if a.get("work_id") == args.work]
        state["attempts"].append({
            "operation_id": args.operation_id or str(uuid.uuid4()),
            "work_id": args.work,
            "attempt": len(prior) + 1,
            "outcome": args.outcome,
            "signature": args.signature,
            "timestamp": now(),
        })
    mutate(repo, "work_attempt", {"work":args.work,"outcome":args.outcome,"signature":args.signature}, apply)
    return 0

def cmd_issue(args) -> int:
    repo = locate_repo(args.repo)
    event_payload = {"id": args.id}
    for key in ("title", "status", "severity", "evidence_class", "path", "notes"):
        value = getattr(args, key)
        if value is not None:
            event_payload[key] = value
    def apply(state):
        existing = next((i for i in state["issues"] if i["id"] == args.id), None)
        record = existing if existing else {"id":args.id}
        if not existing:
            state["issues"].append(record)
        for key in ("title","status","severity","evidence_class","path","notes"):
            value = getattr(args, key)
            if value is not None:
                record[key] = value
        record["updated_at"] = now()
        record.setdefault("created_at", now())
    mutate(repo, "issue_updated", event_payload, apply)
    return 0

def cmd_reference(args) -> int:
    repo = locate_repo(args.repo)
    if args.kind not in {"evidence","decisions","handoffs"}:
        raise SystemExit("Unsupported reference kind")
    def apply(state):
        state[args.kind] = sorted(set(state.get(args.kind, []) + [args.value]))
    mutate(repo, "reference_added", {"kind":args.kind,"value":args.value}, apply)
    return 0

def cmd_status(args) -> int:
    repo = locate_repo(args.repo)
    allowed = {"active","complete","blocked_environment","fatal_invariant"}
    if args.status not in allowed:
        raise SystemExit("Invalid run status")
    def apply(state):
        state["status"] = args.status
    mutate(repo, "run_status", {"status":args.status}, apply)
    return 0

def cmd_validate(args) -> int:
    repo = locate_repo(args.repo)
    package, state_path, events_path, _ = paths(repo)
    state = require_state(state_path)
    errors = []
    if state.get("schema_version") != SCHEMA_VERSION:
        errors.append("unsupported state schema")
    phase_ids = {p["id"] for p in read_json(package/"plans"/"phases.json")["phases"]}
    gate_ids = {g["id"] for g in read_json(package/"plans"/"gates.json")["gates"]}
    if set(state.get("phases",{})) != phase_ids:
        errors.append("phase keys do not match plan")
    if set(state.get("gates",{})) != gate_ids:
        errors.append("gate keys do not match plan")
    previous = None
    expected_sequence = 1
    if events_path.exists():
        for line_number, line in enumerate(events_path.read_text(encoding="utf-8").splitlines(), 1):
            try:
                event = json.loads(line)
                stored_hash = event.pop("event_hash")
                calculated = hashlib.sha256(json.dumps(event, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
                if stored_hash != calculated:
                    errors.append(f"event hash mismatch at line {line_number}")
                if event.get("previous_hash") != previous:
                    errors.append(f"event chain mismatch at line {line_number}")
                if event.get("sequence") != expected_sequence:
                    errors.append(f"event sequence mismatch at line {line_number}")
                previous = stored_hash
                expected_sequence += 1
            except Exception as exc:
                errors.append(f"invalid event at line {line_number}: {exc}")
    if int(state.get("last_event_sequence", -1)) != expected_sequence - 1:
        errors.append("state/event sequence mismatch")
    result = {"valid": not errors, "errors": errors, "state": str(state_path)}
    print(json.dumps(result, indent=2))
    return 0 if not errors else 1

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("init"); p.set_defaults(func=cmd_init)
    p = sub.add_parser("show"); p.add_argument("--compact", action="store_true"); p.set_defaults(func=cmd_show)
    p = sub.add_parser("event"); p.add_argument("type"); p.add_argument("--payload", default="{}"); p.set_defaults(func=cmd_event)
    p = sub.add_parser("phase"); p.add_argument("phase"); p.add_argument("status"); p.add_argument("--error"); p.set_defaults(func=cmd_phase)
    p = sub.add_parser("gate"); p.add_argument("gate"); p.add_argument("status"); p.add_argument("--evidence", action="append"); p.add_argument("--evaluator"); p.set_defaults(func=cmd_gate)
    p = sub.add_parser("attempt"); p.add_argument("work"); p.add_argument("outcome"); p.add_argument("--operation-id"); p.add_argument("--signature"); p.set_defaults(func=cmd_attempt)
    p = sub.add_parser("issue")
    p.add_argument("id")
    p.add_argument("--title")
    p.add_argument("--status", choices=["open","patching","validating","resolved","deferred"])
    p.add_argument("--severity", choices=["Critical","High","Medium","Low"])
    p.add_argument("--evidence-class", choices=["E0","E1","E2","E3"])
    p.add_argument("--path")
    p.add_argument("--notes")
    p.set_defaults(func=cmd_issue)
    p = sub.add_parser("reference"); p.add_argument("kind"); p.add_argument("value"); p.set_defaults(func=cmd_reference)
    p = sub.add_parser("status"); p.add_argument("status"); p.set_defaults(func=cmd_status)
    p = sub.add_parser("validate"); p.set_defaults(func=cmd_validate)
    return parser

def main() -> int:
    return build_parser().parse_args().func(build_parser().parse_args())

if __name__ == "__main__":
    # Parse exactly once; retained as explicit code rather than hidden global state.
    parser = build_parser()
    arguments = parser.parse_args()
    raise SystemExit(arguments.func(arguments))
