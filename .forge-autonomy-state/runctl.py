#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import platform
import shlex
import subprocess
import tempfile
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def canonical(value: dict[str, Any]) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


@contextmanager
def lock(path: Path):
    with path.open("a+") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write((json.dumps(value, indent=2, sort_keys=True) + "\n").encode())
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class StateController:
    def __init__(self, root: Path):
        self.root = root
        self.state_path = root / "run.json"
        self.events_path = root / "events.jsonl"
        self.lock_path = root / ".run.lock"

    def mutate(self, operation: Callable[[dict[str, Any]], dict[str, Any]]) -> tuple[dict[str, Any], dict[str, Any]]:
        with lock(self.lock_path):
            state = json.loads(self.state_path.read_text(encoding="utf-8"))
            event = operation(state)
            atomic_json(self.state_path, state)
        return state, event

    def event(self, state: dict[str, Any], args) -> dict[str, Any]:
        event = {
            "schema_version": 1,
            "timestamp": now(),
            "work_package": args.work_package,
            "action": args.action,
            "command_references": args.command_reference,
            "evidence_references": args.evidence_reference,
            "result": args.result,
            "next_action": args.next_action,
            "prior_event_sha256": state.get("last_event_sha256"),
        }
        event["event_sha256"] = hashlib.sha256(canonical(event)).hexdigest()
        with self.events_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(event, sort_keys=True) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        state["last_event_sha256"] = event["event_sha256"]
        state["updated_at"] = event["timestamp"]
        return event


def root(args) -> Path:
    return Path(args.state_root or ".forge-autonomy-state").resolve()


def event_options(command) -> None:
    command.add_argument("--work-package", required=True)
    command.add_argument("--action", required=True)
    command.add_argument("--command-reference", action="append", default=[])
    command.add_argument("--evidence-reference", action="append", default=[])
    command.add_argument("--result", required=True)
    command.add_argument("--next-action", required=True)


def cmd_start(args) -> int:
    controller = StateController(root(args))

    def operation(state):
        if state.get("run_id") is not None:
            raise SystemExit("run already started")
        state["run_id"] = str(uuid.uuid4())
        state["status"] = "active"
        state["started_at"] = now()
        return controller.event(state, args)

    state, event = controller.mutate(operation)
    print(json.dumps({"run_id": state["run_id"], "event": event}, indent=2, sort_keys=True))
    return 0


def cmd_event(args) -> int:
    controller = StateController(root(args))
    state, event = controller.mutate(lambda state: controller.event(state, args))
    print(json.dumps({"run_id": state["run_id"], "event": event}, indent=2, sort_keys=True))
    return 0


def cmd_complete(args) -> int:
    controller = StateController(root(args))

    def operation(state):
        completed = state.setdefault("completed_work_packages", [])
        if args.work_package not in completed:
            completed.append(args.work_package)
        state["blocked_work_packages"] = [item for item in state.get("blocked_work_packages", []) if item != args.work_package]
        state["current_work_package"] = args.next_work_package
        if args.next_work_package is None:
            state["status"] = "complete"
            state["completed_at"] = now()
        return controller.event(state, args)

    state, event = controller.mutate(operation)
    print(json.dumps({"state": state, "event": event}, indent=2, sort_keys=True))
    return 0


def cmd_validate(args) -> int:
    controller = StateController(root(args))
    state = json.loads(controller.state_path.read_text(encoding="utf-8"))
    errors: list[str] = []
    prior = None
    count = 0
    for count, line in enumerate(controller.events_path.read_text(encoding="utf-8").splitlines(), 1):
        event = json.loads(line)
        stored = event.pop("event_sha256", None)
        calculated = hashlib.sha256(canonical(event)).hexdigest()
        if stored != calculated:
            errors.append(f"event hash mismatch at line {count}")
        if event.get("prior_event_sha256") != prior:
            errors.append(f"event chain mismatch at line {count}")
        prior = stored
    if state.get("last_event_sha256") != prior:
        errors.append("run state does not reference final event")
    print(json.dumps({"valid": not errors, "event_count": count, "errors": errors}, indent=2, sort_keys=True))
    return 0 if not errors else 1


def cmd_record(args) -> int:
    command = args.command[1:] if args.command and args.command[0] == "--" else args.command
    if not command:
        raise SystemExit("a command is required after --")
    state_root = root(args)
    working_directory = Path(args.cwd).resolve()
    log_dir = state_root / "command-logs" / args.work_package
    log_dir.mkdir(parents=True, exist_ok=True)
    record_id = f"CMD-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex[:10]}"
    stdout_path = log_dir / f"{record_id}.stdout.txt"
    stderr_path = log_dir / f"{record_id}.stderr.txt"
    started = now()
    timed_out = False
    try:
        with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
            result = subprocess.run(command, cwd=working_directory, stdout=stdout, stderr=stderr, timeout=args.timeout)
            exit_code = result.returncode
    except subprocess.TimeoutExpired:
        exit_code = 124
        timed_out = True
    record = {
        "schema_version": 1,
        "id": record_id,
        "work_package": args.work_package,
        "command": shlex.join(command),
        "cwd": str(working_directory),
        "started_at": started,
        "ended_at": now(),
        "exit_code": exit_code,
        "timed_out": timed_out,
        "environment": {"platform": platform.platform(), "machine": platform.machine()},
        "stdout": {"path": str(stdout_path.relative_to(state_root.parent)), "sha256": file_hash(stdout_path), "bytes": stdout_path.stat().st_size},
        "stderr": {"path": str(stderr_path.relative_to(state_root.parent)), "sha256": file_hash(stderr_path), "bytes": stderr_path.stat().st_size},
    }
    commands_path = log_dir / "commands.jsonl"
    with lock(log_dir / ".commands.lock"):
        with commands_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
    print(json.dumps(record, indent=2, sort_keys=True))
    return exit_code


def build_parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--state-root")
    commands = result.add_subparsers(dest="command_name", required=True)
    start = commands.add_parser("start")
    event_options(start)
    start.set_defaults(handler=cmd_start)
    event = commands.add_parser("event")
    event_options(event)
    event.set_defaults(handler=cmd_event)
    complete = commands.add_parser("complete")
    event_options(complete)
    complete.add_argument("--next-work-package")
    complete.set_defaults(handler=cmd_complete)
    validate = commands.add_parser("validate")
    validate.set_defaults(handler=cmd_validate)
    record = commands.add_parser("record")
    record.add_argument("--work-package", required=True)
    record.add_argument("--cwd", default=".")
    record.add_argument("--timeout", type=int, default=1800)
    record.add_argument("command", nargs=argparse.REMAINDER)
    record.set_defaults(handler=cmd_record)
    return result


if __name__ == "__main__":
    parsed = build_parser().parse_args()
    raise SystemExit(parsed.handler(parsed))
