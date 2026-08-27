#!/usr/bin/env python3
"""Run one bounded command and persist command-backed evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import platform
import selectors
import shlex
import signal
import stat
import subprocess
import time
import uuid
from datetime import datetime, timezone
from typing import Any

from evidence_support import EvidenceSupportError, atomic_write_json, sha256_file, source_manifest


MAXIMUM_PRESERVED_ARTIFACT_BYTES = 64 * 1024 * 1024
MAXIMUM_EXTERNAL_ARTIFACT_BYTES = 16 * 1024 * 1024 * 1024
MAXIMUM_CAPTURED_STREAM_BYTES = 64 * 1024 * 1024
LEDGER_DIAGNOSTIC_BYTES = 4096
TERMINATION_GRACE_SECONDS = 1.0
TERMINATION_WAIT_SECONDS = 2.0


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def repository_relative(path: pathlib.Path, repository: pathlib.Path) -> pathlib.Path:
    resolved = path.resolve(strict=True)
    try:
        relative = resolved.relative_to(repository)
    except ValueError as error:
        raise EvidenceSupportError(f"artifact is outside the repository: {path}") from error
    candidate = repository
    for part in relative.parts:
        candidate = candidate / part
        if candidate.is_symlink():
            raise EvidenceSupportError(f"artifact path contains a symbolic link: {path}")
    return relative


def regular_file_metadata(path: pathlib.Path) -> os.stat_result:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        metadata = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if not stat.S_ISREG(metadata.st_mode):
        raise EvidenceSupportError(f"artifact is not a regular file: {path}")
    return metadata


def secure_copy(
    source: pathlib.Path,
    destination: pathlib.Path,
    *,
    maximum_bytes: int,
) -> tuple[str, int]:
    source_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    destination_flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    source_descriptor = os.open(source, source_flags)
    destination_descriptor: int | None = None
    try:
        before = os.fstat(source_descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
        ):
            raise EvidenceSupportError(
                f"artifact is not an owner-controlled, singly linked regular file: {source}"
            )
        if before.st_size > maximum_bytes:
            raise EvidenceSupportError(f"artifact exceeds {maximum_bytes} bytes: {source}")
        destination_descriptor = os.open(destination, destination_flags, 0o600)
        digest = hashlib.sha256()
        total = 0
        while True:
            block = os.read(source_descriptor, min(1024 * 1024, maximum_bytes - total + 1))
            if not block:
                break
            total += len(block)
            if total > maximum_bytes:
                raise EvidenceSupportError(f"artifact exceeds {maximum_bytes} bytes: {source}")
            digest.update(block)
            offset = 0
            while offset < len(block):
                written = os.write(destination_descriptor, block[offset:])
                if written <= 0:
                    raise EvidenceSupportError(f"artifact copy made no progress: {source}")
                offset += written
        os.fsync(destination_descriptor)
        after = os.fstat(source_descriptor)
        if (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
        ) != (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
        ):
            raise EvidenceSupportError(f"artifact changed while it was copied: {source}")
        os.fchmod(destination_descriptor, 0o444)
        return digest.hexdigest(), total
    except Exception:
        destination.unlink(missing_ok=True)
        raise
    finally:
        os.close(source_descriptor)
        if destination_descriptor is not None:
            os.close(destination_descriptor)


def preserve_artifact(
    source: pathlib.Path,
    destination: pathlib.Path,
    repository: pathlib.Path,
    *,
    maximum_bytes: int,
) -> dict[str, Any]:
    relative_source = repository_relative(source, repository)
    regular_file_metadata(source)
    digest, byte_count = secure_copy(source, destination, maximum_bytes=maximum_bytes)
    return {
        "path": destination.relative_to(repository).as_posix(),
        "source_path": relative_source.as_posix(),
        "sha256": digest,
        "bytes": byte_count,
        "storage": "evidence-id-specific-copy",
    }


def reference_external_artifact(
    source: pathlib.Path,
    repository: pathlib.Path,
    *,
    maximum_bytes: int,
) -> dict[str, Any]:
    if not source.is_absolute():
        raise EvidenceSupportError(f"external artifact path must be absolute: {source}")
    resolved = source.resolve(strict=True)
    try:
        resolved.relative_to(repository)
    except ValueError:
        pass
    else:
        raise EvidenceSupportError(
            f"repository artifacts must use --artifact instead of --external-artifact: {source}"
        )
    if source.is_symlink():
        raise EvidenceSupportError(f"external artifact is a symbolic link: {source}")
    metadata = regular_file_metadata(source)
    if metadata.st_size > maximum_bytes:
        raise EvidenceSupportError(f"external artifact exceeds {maximum_bytes} bytes: {source}")
    digest, byte_count = sha256_file(resolved, maximum_bytes=maximum_bytes)
    return {
        "path": str(resolved),
        "sha256": digest,
        "bytes": byte_count,
        "storage": "external-hash-only",
        "portability": "origin-host-required",
    }


def open_owner_only(path: pathlib.Path):
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    return os.fdopen(os.open(path, flags, 0o600), "wb")


def terminate_process_group(process: subprocess.Popen[Any]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        pass

    grace_deadline = time.monotonic() + TERMINATION_GRACE_SECONDS
    while time.monotonic() < grace_deadline:
        process.poll()
        try:
            os.killpg(process.pid, 0)
        except (ProcessLookupError, PermissionError):
            break
        time.sleep(0.05)

    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        process.wait(timeout=TERMINATION_WAIT_SECONDS)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=TERMINATION_WAIT_SECONDS)


def execute_command(
    command: list[str],
    repository: pathlib.Path,
    stdout_path: pathlib.Path,
    stderr_path: pathlib.Path,
    timeout_seconds: int,
    maximum_stream_bytes: int,
) -> tuple[int, bool, bool]:
    timed_out = False
    stream_limit_exceeded = False
    with open_owner_only(stdout_path) as stdout_stream, open_owner_only(stderr_path) as stderr_stream:
        process = subprocess.Popen(
            command,
            cwd=repository,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
            bufsize=0,
        )
        assert process.stdout is not None
        assert process.stderr is not None
        selector = selectors.DefaultSelector()
        outputs = {
            process.stdout.fileno(): (process.stdout, stdout_stream),
            process.stderr.fileno(): (process.stderr, stderr_stream),
        }
        totals = {descriptor: 0 for descriptor in outputs}
        for descriptor, (pipe, _) in outputs.items():
            os.set_blocking(descriptor, False)
            selector.register(pipe, selectors.EVENT_READ, descriptor)

        deadline = time.monotonic() + timeout_seconds
        terminated = False
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0 and not terminated:
                timed_out = True
                terminate_process_group(process)
                terminated = True
                break
            events = selector.select(timeout=max(0.0, min(0.1, remaining)))
            for key, _ in events:
                descriptor = key.data
                pipe, destination = outputs[descriptor]
                try:
                    block = os.read(descriptor, 64 * 1024)
                except BlockingIOError:
                    continue
                if not block:
                    selector.unregister(pipe)
                    pipe.close()
                    continue
                allowed = max(0, maximum_stream_bytes - totals[descriptor])
                if allowed:
                    destination.write(block[:allowed])
                    totals[descriptor] += min(len(block), allowed)
                if len(block) > allowed:
                    stream_limit_exceeded = True
                    if not terminated:
                        terminate_process_group(process)
                        terminated = True
            if terminated:
                break

        for key in list(selector.get_map().values()):
            selector.unregister(key.fileobj)
            key.fileobj.close()
        selector.close()
        if timed_out:
            exit_code = 124
        else:
            remaining = max(0.0, deadline - time.monotonic())
            try:
                exit_code = process.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                timed_out = True
                terminate_process_group(process)
                exit_code = 124
        for stream in (stdout_stream, stderr_stream):
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), 0o444)
    return exit_code, timed_out, stream_limit_exceeded


def build_parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser()
    value.add_argument("--repo", default=".")
    value.add_argument("--kind", required=True)
    value.add_argument("--related-gate", action="append", default=[])
    value.add_argument("--related-finding", action="append", default=[])
    value.add_argument("--timeout", type=int, default=1800)
    value.add_argument("--artifact", action="append", default=[])
    value.add_argument("--external-artifact", action="append", default=[])
    value.add_argument(
        "--maximum-preserved-artifact-bytes",
        type=int,
        default=MAXIMUM_PRESERVED_ARTIFACT_BYTES,
    )
    value.add_argument(
        "--maximum-external-artifact-bytes",
        type=int,
        default=MAXIMUM_EXTERNAL_ARTIFACT_BYTES,
    )
    value.add_argument(
        "--maximum-stream-bytes",
        type=int,
        default=MAXIMUM_CAPTURED_STREAM_BYTES,
    )
    value.add_argument("command", nargs=argparse.REMAINDER)
    return value


def main() -> int:
    arguments = build_parser().parse_args()
    if arguments.command and arguments.command[0] == "--":
        arguments.command = arguments.command[1:]
    if not arguments.command:
        raise SystemExit("A command is required after --")
    if arguments.timeout <= 0:
        raise SystemExit("--timeout must be positive")
    if arguments.maximum_preserved_artifact_bytes <= 0:
        raise SystemExit("--maximum-preserved-artifact-bytes must be positive")
    if arguments.maximum_external_artifact_bytes <= 0:
        raise SystemExit("--maximum-external-artifact-bytes must be positive")
    if arguments.maximum_stream_bytes <= 0:
        raise SystemExit("--maximum-stream-bytes must be positive")

    repository = pathlib.Path(arguments.repo).resolve(strict=True)
    evidence_directory = repository / ".forge-codex/evidence"
    evidence_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    evidence_id = (
        f"EVID-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex[:10]}"
    )
    stdout_path = evidence_directory / f"{evidence_id}.stdout.txt"
    stderr_path = evidence_directory / f"{evidence_id}.stderr.txt"
    record_path = evidence_directory / f"{evidence_id}.json"

    manifest_before = source_manifest(repository)
    started_at = now()
    command_exit_code, timed_out, stream_limit_exceeded = execute_command(
        arguments.command,
        repository,
        stdout_path,
        stderr_path,
        arguments.timeout,
        arguments.maximum_stream_bytes,
    )
    ended_at = now()

    artifacts: list[dict[str, Any]] = []
    capture_errors: list[dict[str, str]] = []
    for index, raw in enumerate(arguments.artifact):
        source = (repository / raw) if not pathlib.Path(raw).is_absolute() else pathlib.Path(raw)
        destination = evidence_directory / f"{evidence_id}.artifact-{index:03d}-{source.name}"
        try:
            artifacts.append(
                preserve_artifact(
                    source,
                    destination,
                    repository,
                    maximum_bytes=arguments.maximum_preserved_artifact_bytes,
                )
            )
        except (OSError, ValueError, EvidenceSupportError) as error:
            capture_errors.append({"source_path": str(source), "error": str(error)})
    for raw in arguments.external_artifact:
        source = pathlib.Path(raw)
        try:
            artifacts.append(
                reference_external_artifact(
                    source,
                    repository,
                    maximum_bytes=arguments.maximum_external_artifact_bytes,
                )
            )
        except (OSError, ValueError, EvidenceSupportError) as error:
            capture_errors.append({"source_path": str(source), "error": str(error)})

    for stream_path in (stdout_path, stderr_path):
        digest, byte_count = sha256_file(stream_path)
        artifacts.append({
            "path": stream_path.relative_to(repository).as_posix(),
            "sha256": digest,
            "bytes": byte_count,
            "storage": "evidence-id-specific-stream",
        })

    manifest_after = source_manifest(repository)
    source_changed = manifest_before != manifest_after
    provisional_exit_code = command_exit_code
    if capture_errors:
        provisional_exit_code = 125
    elif source_changed:
        provisional_exit_code = 126
    elif stream_limit_exceeded:
        provisional_exit_code = 127
    record: dict[str, Any] = {
        "schema_version": 2,
        "id": evidence_id,
        "kind": arguments.kind,
        "command": shlex.join(arguments.command),
        "exit_code": provisional_exit_code,
        "timed_out": timed_out,
        "stream_limit_exceeded": stream_limit_exceeded,
        "maximum_stream_bytes": arguments.maximum_stream_bytes,
        "started_at": started_at,
        "ended_at": ended_at,
        "environment": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "cwd": str(repository),
        },
        "source_manifest": manifest_before,
        "source_manifest_after": manifest_after,
        "source_manifest_changed": source_changed,
        "artifacts": artifacts,
        "artifact_capture_errors": capture_errors,
        "ledger_reference": {"status": "pending"},
        "related_findings": arguments.related_finding,
        "related_gates": arguments.related_gate,
    }
    if provisional_exit_code != command_exit_code:
        record["command_exit_code"] = command_exit_code
    atomic_write_json(record_path, record)

    try:
        ledger = subprocess.run(
            [
                str(repository / ".forge-codex/scripts/statectl.py"),
                "--repo",
                str(repository),
                "reference",
                "evidence",
                evidence_id,
            ],
            cwd=repository,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
            check=False,
        )
        if ledger.returncode == 0:
            ledger_status: dict[str, Any] = {"status": "recorded", "exit_code": 0}
        else:
            ledger_status = {
                "status": "failed",
                "exit_code": ledger.returncode,
                "stderr": ledger.stderr[-LEDGER_DIAGNOSTIC_BYTES:].decode("utf-8", errors="replace"),
            }
    except (OSError, subprocess.SubprocessError) as error:
        ledger_status = {"status": "failed", "error": str(error)}

    record_exit_code = command_exit_code
    if capture_errors or ledger_status["status"] != "recorded":
        record_exit_code = 125
    elif source_changed:
        record_exit_code = 126
    elif stream_limit_exceeded:
        record_exit_code = 127

    record["exit_code"] = record_exit_code
    record["ledger_reference"] = ledger_status
    if record_exit_code != command_exit_code:
        record["command_exit_code"] = command_exit_code
    else:
        record.pop("command_exit_code", None)
    atomic_write_json(record_path, record)
    print(json.dumps(record, indent=2, sort_keys=True))
    return record_exit_code


if __name__ == "__main__":
    raise SystemExit(main())
