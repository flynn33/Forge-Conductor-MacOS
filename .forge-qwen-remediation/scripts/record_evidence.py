#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import platform
import subprocess
import uuid
from pathlib import Path

from integrity import canonical_sha256
from source_manifest import manifest


def main() -> int:
    parser = argparse.ArgumentParser(description="Run a bounded command and record immutable supporting evidence")
    parser.add_argument("--repo", default=".")
    parser.add_argument("--work-package", required=True)
    parser.add_argument("--gate")
    parser.add_argument("--kind", required=True)
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command and args.command[0] == "--" else args.command
    if not command:
        raise SystemExit("command required after --")

    repo = Path(args.repo).resolve()
    evidence_root = repo / ".forge-qwen-state/evidence"
    evidence_root.mkdir(parents=True, exist_ok=True)
    evidence_id = "EVID-" + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:12]
    before = manifest(repo)
    started = dt.datetime.now(dt.timezone.utc)
    timed_out = False
    try:
        process = subprocess.run(
            command,
            cwd=repo,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=max(1, args.timeout),
            check=False,
        )
        exit_code = process.returncode
        stdout = process.stdout
        stderr = process.stderr
    except subprocess.TimeoutExpired as error:
        timed_out = True
        exit_code = None
        stdout = error.stdout or b""
        stderr = error.stderr or b""

    maximum_stream_bytes = 64 * 1024 * 1024
    stdout_truncated = len(stdout) > maximum_stream_bytes
    stderr_truncated = len(stderr) > maximum_stream_bytes
    stdout = stdout[:maximum_stream_bytes]
    stderr = stderr[:maximum_stream_bytes]
    stdout_path = evidence_root / f"{evidence_id}.stdout"
    stderr_path = evidence_root / f"{evidence_id}.stderr"
    stdout_path.write_bytes(stdout)
    stderr_path.write_bytes(stderr)
    after = manifest(repo)
    ended = dt.datetime.now(dt.timezone.utc)
    artifacts = []
    for role, path in (("stdout", stdout_path), ("stderr", stderr_path)):
        data = path.read_bytes()
        artifacts.append({
            "role": role,
            "path": path.relative_to(repo).as_posix(),
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        })
    status = "timed_out" if timed_out else ("passed" if exit_code == 0 else "failed")
    record = {
        "schema_version": 1,
        "evidence_id": evidence_id,
        "kind": args.kind,
        "work_package": args.work_package,
        "gate_id": args.gate,
        "command": command,
        "cwd": ".",
        "environment": {
            "platform": platform.platform(),
            "machine": platform.machine(),
        },
        "source_manifest_before": before["manifest_sha256"],
        "source_manifest_after": after["manifest_sha256"],
        "started_at": started.isoformat(),
        "ended_at": ended.isoformat(),
        "duration_milliseconds": int((ended - started).total_seconds() * 1000),
        "status": status,
        "exit_code": exit_code,
        "maximum_stream_bytes": maximum_stream_bytes,
        "stdout_truncated": stdout_truncated,
        "stderr_truncated": stderr_truncated,
        "artifacts": artifacts,
        "record_sha256": "",
    }
    record["record_sha256"] = canonical_sha256(record, "record_sha256")
    receipt_path = evidence_root / f"{evidence_id}.json"
    receipt_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    receipt_path.chmod(0o444)
    print(json.dumps(record, indent=2))
    return 0 if exit_code == 0 and not timed_out else 1


if __name__ == "__main__":
    raise SystemExit(main())
