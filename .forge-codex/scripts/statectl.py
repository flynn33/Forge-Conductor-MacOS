#!/usr/bin/env python3
from __future__ import annotations

import argparse
import errno
import fcntl
import hashlib
import json
import os
import re
import stat
import sys
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from evidence_support import (
    BoundedReadBudget,
    EvidenceSupportError,
    current_git_head,
    decode_strict_json_object,
    load_bounded_repository_json_object,
    run_bounded_readonly_command,
    sha256_bounded_repository_file,
    source_manifest,
)

SCHEMA_VERSION = 1
MAXIMUM_STATE_JSON_BYTES = 1024 * 1024
MAXIMUM_PLAN_JSON_BYTES = 1024 * 1024
MAXIMUM_GATE_RESULT_JSON_BYTES = 1024 * 1024
MAXIMUM_GATE_ARTIFACT_BYTES = 64 * 1024 * 1024
MAXIMUM_GATE_ARTIFACT_AGGREGATE_BYTES = 512 * 1024 * 1024
MAXIMUM_CONTROL_JSON_AGGREGATE_BYTES = 64 * 1024 * 1024
MAXIMUM_EVENT_BYTES = 1024 * 1024
MAXIMUM_EVENT_LEDGER_BYTES = 64 * 1024 * 1024
MAXIMUM_REPOSITORY_STATUS_BYTES = 16 * 1024 * 1024
MAXIMUM_EVENT_COUNT = 100_000
MAXIMUM_TRANSACTION_BYTES = 4 * 1024 * 1024
STATE_LOCK_TIMEOUT_SECONDS = 2.0
STATE_LOCK_RETRY_SECONDS = 0.05
STATE_FILE_NAME = "run-state.json"
EVENT_FILE_NAME = "events.jsonl"
LOCK_FILE_NAME = ".state.lock"
TRANSACTION_FILE_NAME = ".state-transaction.json"
STATE_STAGING_FILE_NAME = f".{STATE_FILE_NAME}.staging"
TRANSACTION_STAGING_FILE_NAME = f".{TRANSACTION_FILE_NAME}.staging"
OPERATION_IDENTIFIER_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")

def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def operation_identifier(value: str | None) -> str:
    if value is None:
        return str(uuid.uuid4())
    if OPERATION_IDENTIFIER_PATTERN.fullmatch(value) is None:
        raise EvidenceSupportError("state operation identifier is invalid")
    return value

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


def directory_open_flags() -> int:
    return (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_DIRECTORY", 0)
    )


def regular_open_flags(*, read_write: bool, create: bool = False) -> int:
    flags = os.O_RDWR if read_write else os.O_RDONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)
    if create:
        flags |= os.O_CREAT
    return flags


def require_secure_directory(metadata: os.stat_result, label: str) -> None:
    if not stat.S_ISDIR(metadata.st_mode):
        raise EvidenceSupportError(f"{label} is not a directory")
    if metadata.st_uid != os.geteuid():
        raise EvidenceSupportError(f"{label} is not owned by the current user")
    if metadata.st_mode & 0o022:
        raise EvidenceSupportError(f"{label} is group- or world-writable")


def require_directory_identity(
    current: os.stat_result,
    expected: os.stat_result,
    label: str,
) -> None:
    require_secure_directory(current, label)
    if not same_identity(current, expected):
        raise EvidenceSupportError(f"{label} pathname identity changed")


def require_secure_regular(metadata: os.stat_result, label: str) -> None:
    if not stat.S_ISREG(metadata.st_mode):
        raise EvidenceSupportError(f"{label} is not a regular file")
    if metadata.st_uid != os.geteuid():
        raise EvidenceSupportError(f"{label} is not owned by the current user")
    if metadata.st_nlink != 1:
        raise EvidenceSupportError(f"{label} has multiple hard links")
    if metadata.st_mode & 0o022:
        raise EvidenceSupportError(f"{label} is group- or world-writable")


def same_identity(left: os.stat_result, right: os.stat_result) -> bool:
    return (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)


@contextmanager
def open_state_directory(repo: Path, *, create: bool):
    root_descriptor: int | None = None
    package_descriptor: int | None = None
    state_descriptor: int | None = None
    flags = directory_open_flags()
    try:
        root_descriptor = os.open(repo, flags)
        root_identity = os.fstat(root_descriptor)
        require_secure_directory(root_identity, "repository root")
        package_descriptor = os.open(
            ".forge-codex",
            flags,
            dir_fd=root_descriptor,
        )
        package_identity = os.fstat(package_descriptor)
        require_secure_directory(package_identity, ".forge-codex directory")
        try:
            state_descriptor = os.open(
                "state",
                flags,
                dir_fd=package_descriptor,
            )
        except FileNotFoundError:
            if not create:
                raise EvidenceSupportError("state directory is absent")
            os.mkdir("state", mode=0o700, dir_fd=package_descriptor)
            os.fsync(package_descriptor)
            state_descriptor = os.open(
                "state",
                flags,
                dir_fd=package_descriptor,
            )
        state_identity = os.fstat(state_descriptor)
        require_secure_directory(state_identity, "state directory")
        yield state_descriptor
        require_directory_identity(
            os.stat(repo, follow_symlinks=False),
            root_identity,
            "repository root",
        )
        require_directory_identity(
            os.stat(
                ".forge-codex",
                dir_fd=root_descriptor,
                follow_symlinks=False,
            ),
            package_identity,
            ".forge-codex directory",
        )
        require_directory_identity(
            os.stat(
                "state",
                dir_fd=package_descriptor,
                follow_symlinks=False,
            ),
            state_identity,
            "state directory",
        )
    except OSError as error:
        raise EvidenceSupportError(
            f"state directory is unavailable or contains a symlink: {error}"
        ) from error
    finally:
        for descriptor in (state_descriptor, package_descriptor, root_descriptor):
            if descriptor is not None:
                os.close(descriptor)


def stat_path_at(directory_descriptor: int, name: str) -> os.stat_result | None:
    try:
        return os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return None


def require_path_identity(
    directory_descriptor: int,
    name: str,
    expected: os.stat_result,
    label: str,
) -> None:
    current = stat_path_at(directory_descriptor, name)
    if current is None or not same_identity(current, expected):
        raise EvidenceSupportError(f"{label} pathname identity changed")
    require_secure_regular(current, label)


def open_regular_at(
    directory_descriptor: int,
    name: str,
    *,
    label: str,
    read_write: bool,
    create: bool = False,
) -> tuple[int, os.stat_result]:
    try:
        descriptor = os.open(
            name,
            regular_open_flags(read_write=read_write, create=create),
            0o600,
            dir_fd=directory_descriptor,
        )
    except OSError as error:
        raise EvidenceSupportError(f"{label} is unavailable: {error}") from error
    try:
        metadata = os.fstat(descriptor)
        require_secure_regular(metadata, label)
        require_path_identity(directory_descriptor, name, metadata, label)
        return descriptor, metadata
    except Exception:
        os.close(descriptor)
        raise


def read_bounded_descriptor(
    descriptor: int,
    initial: os.stat_result,
    *,
    label: str,
    maximum_bytes: int,
    budget: BoundedReadBudget | None = None,
) -> bytes:
    if initial.st_size > maximum_bytes:
        raise EvidenceSupportError(
            f"{label} exceeds its {maximum_bytes}-byte file read bound"
        )
    if budget is not None:
        budget.ensure_capacity(initial.st_size, label)
    os.lseek(descriptor, 0, os.SEEK_SET)
    chunks: list[bytes] = []
    total = 0
    while True:
        block = os.read(descriptor, min(64 * 1024, maximum_bytes - total + 1))
        if not block:
            break
        total += len(block)
        if total > maximum_bytes:
            raise EvidenceSupportError(
                f"{label} exceeds its {maximum_bytes}-byte file read bound"
            )
        chunks.append(block)
    final = os.fstat(descriptor)
    if (
        not same_identity(initial, final)
        or final.st_size != initial.st_size
        or final.st_mtime_ns != initial.st_mtime_ns
        or final.st_ctime_ns != initial.st_ctime_ns
    ):
        raise EvidenceSupportError(f"{label} changed during its bounded read")
    if budget is not None:
        budget.consume(total, label)
    return b"".join(chunks)


def read_bytes_at(
    directory_descriptor: int,
    name: str,
    *,
    label: str,
    maximum_bytes: int,
    budget: BoundedReadBudget | None = None,
) -> bytes:
    descriptor, metadata = open_regular_at(
        directory_descriptor,
        name,
        label=label,
        read_write=False,
    )
    try:
        raw = read_bounded_descriptor(
            descriptor,
            metadata,
            label=label,
            maximum_bytes=maximum_bytes,
            budget=budget,
        )
        require_path_identity(directory_descriptor, name, metadata, label)
        return raw
    finally:
        os.close(descriptor)


def read_json_at(
    directory_descriptor: int,
    name: str,
    *,
    label: str,
    maximum_bytes: int,
    budget: BoundedReadBudget | None = None,
) -> dict[str, Any]:
    return decode_strict_json_object(
        read_bytes_at(
            directory_descriptor,
            name,
            label=label,
            maximum_bytes=maximum_bytes,
            budget=budget,
        ),
        label=label,
    )


def unlink_secure_file_at(
    directory_descriptor: int,
    name: str,
    *,
    label: str,
    missing_ok: bool,
) -> None:
    metadata = stat_path_at(directory_descriptor, name)
    if metadata is None:
        if missing_ok:
            return
        raise EvidenceSupportError(f"{label} is absent")
    require_secure_regular(metadata, label)
    try:
        os.unlink(name, dir_fd=directory_descriptor)
        os.fsync(directory_descriptor)
    except OSError as error:
        raise EvidenceSupportError(f"{label} could not be removed: {error}") from error


def cleanup_staging_file(
    directory_descriptor: int,
    name: str,
    *,
    label: str,
) -> None:
    unlink_secure_file_at(
        directory_descriptor,
        name,
        label=label,
        missing_ok=True,
    )


@contextmanager
def locked_state_directory(repo: Path, *, create: bool):
    with open_state_directory(repo, create=create) as state_descriptor:
        descriptor, metadata = open_regular_at(
            state_descriptor,
            LOCK_FILE_NAME,
            label="state lock",
            read_write=True,
            create=True,
        )
        deadline = time.monotonic() + STATE_LOCK_TIMEOUT_SECONDS
        try:
            while True:
                try:
                    fcntl.flock(
                        descriptor,
                        fcntl.LOCK_EX | fcntl.LOCK_NB,
                    )
                    break
                except OSError as error:
                    if error.errno not in {errno.EACCES, errno.EAGAIN}:
                        raise EvidenceSupportError(
                            f"state lock acquisition failed: {error}"
                        ) from error
                    if time.monotonic() >= deadline:
                        raise EvidenceSupportError(
                            "state lock exceeded its acquisition time bound"
                        ) from error
                    time.sleep(STATE_LOCK_RETRY_SECONDS)
            require_path_identity(
                state_descriptor,
                LOCK_FILE_NAME,
                metadata,
                "state lock",
            )
            yield state_descriptor
            require_path_identity(
                state_descriptor,
                LOCK_FILE_NAME,
                metadata,
                "state lock",
            )
        finally:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            finally:
                os.close(descriptor)

def encoded_json(value: Any, *, label: str, maximum_bytes: int) -> bytes:
    try:
        encoded = (
            json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n"
        ).encode("utf-8")
    except (TypeError, ValueError, UnicodeError) as error:
        raise EvidenceSupportError(f"{label} is not finite UTF-8 JSON: {error}") from error
    if len(encoded) > maximum_bytes:
        raise EvidenceSupportError(
            f"{label} exceeds its {maximum_bytes}-byte write bound"
        )
    return encoded


def write_all(descriptor: int, raw: bytes, label: str) -> None:
    offset = 0
    while offset < len(raw):
        written = os.write(descriptor, raw[offset:])
        if written <= 0:
            raise EvidenceSupportError(f"{label} write made no progress")
        offset += written


def atomic_bytes_at(
    directory_descriptor: int,
    final_name: str,
    staging_name: str,
    raw: bytes,
    *,
    label: str,
) -> None:
    existing = stat_path_at(directory_descriptor, final_name)
    if existing is not None:
        require_secure_regular(existing, label)
    cleanup_staging_file(
        directory_descriptor,
        staging_name,
        label=f"{label} staging file",
    )
    try:
        descriptor = os.open(
            staging_name,
            regular_open_flags(read_write=True) | os.O_CREAT | os.O_EXCL,
            0o600,
            dir_fd=directory_descriptor,
        )
    except OSError as error:
        raise EvidenceSupportError(f"{label} staging file is unavailable: {error}") from error
    staged: os.stat_result | None = None
    try:
        staged = os.fstat(descriptor)
        require_secure_regular(staged, f"{label} staging file")
        write_all(descriptor, raw, label)
        os.fsync(descriptor)
        after = os.fstat(descriptor)
        if not same_identity(staged, after) or after.st_size != len(raw):
            raise EvidenceSupportError(f"{label} staging file changed during write")
        require_path_identity(
            directory_descriptor,
            staging_name,
            after,
            f"{label} staging file",
        )
    finally:
        os.close(descriptor)
    try:
        os.replace(
            staging_name,
            final_name,
            src_dir_fd=directory_descriptor,
            dst_dir_fd=directory_descriptor,
        )
        os.fsync(directory_descriptor)
    except OSError as error:
        raise EvidenceSupportError(f"{label} atomic replace failed: {error}") from error
    if staged is None:
        raise EvidenceSupportError(f"{label} staging identity is absent")
    require_path_identity(directory_descriptor, final_name, staged, label)


def atomic_json_at(
    directory_descriptor: int,
    final_name: str,
    staging_name: str,
    value: Any,
    *,
    label: str,
    maximum_bytes: int,
) -> None:
    encoded = encoded_json(value, label=label, maximum_bytes=maximum_bytes)
    atomic_bytes_at(
        directory_descriptor,
        final_name,
        staging_name,
        encoded,
        label=label,
    )

def control_budget() -> BoundedReadBudget:
    return BoundedReadBudget(
        MAXIMUM_CONTROL_JSON_AGGREGATE_BYTES,
        "state control JSON",
    )


def read_json(
    repo: Path,
    path: Path,
    *,
    label: str,
    maximum_bytes: int,
    budget: BoundedReadBudget,
) -> dict[str, Any]:
    try:
        relative = path.relative_to(repo).as_posix()
    except ValueError as error:
        raise EvidenceSupportError(f"{label} is outside the repository") from error
    return load_bounded_repository_json_object(
        repo,
        relative,
        label=label,
        maximum_bytes=maximum_bytes,
        budget=budget,
    )

def repository_state(repo: Path) -> dict[str, Any]:
    def run(*args: str) -> str | None:
        try:
            return_code, stdout, _ = run_bounded_readonly_command(
                repo,
                f"repository state command {args[0]}",
                list(args),
                timeout_seconds=10,
                maximum_output_bytes=MAXIMUM_REPOSITORY_STATUS_BYTES,
            )
            if return_code != 0:
                return None
            return stdout.decode("utf-8", errors="strict").strip()
        except (EvidenceSupportError, UnicodeError):
            return None
    git_present = (repo / ".git").exists()
    status = run("git", "status", "--porcelain=v1") if git_present else None
    return {
        "root": str(repo),
        "branch": run("git", "branch", "--show-current"),
        "commit": run("git", "rev-parse", "HEAD"),
        "dirty": bool(status) if status is not None else git_present,
    }

def event_hash(event_without_hash: dict[str, Any]) -> str:
    try:
        canonical = json.dumps(
            event_without_hash,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError, UnicodeError) as error:
        raise EvidenceSupportError(f"state event is not canonical JSON: {error}") from error
    return hashlib.sha256(canonical).hexdigest()


def encoded_event(event: dict[str, Any]) -> bytes:
    try:
        raw = (json.dumps(event, sort_keys=True, allow_nan=False) + "\n").encode(
            "utf-8"
        )
    except (TypeError, ValueError, UnicodeError) as error:
        raise EvidenceSupportError(f"state event is not finite UTF-8 JSON: {error}") from error
    if len(raw) > MAXIMUM_EVENT_BYTES:
        raise EvidenceSupportError(
            f"state event exceeds its {MAXIMUM_EVENT_BYTES}-byte line bound"
        )
    return raw


def validate_event_ledger(raw: bytes) -> tuple[int, str | None]:
    if len(raw) > MAXIMUM_EVENT_LEDGER_BYTES:
        raise EvidenceSupportError(
            f"state event ledger exceeds its {MAXIMUM_EVENT_LEDGER_BYTES}-byte bound"
        )
    if not raw:
        return 0, None
    if not raw.endswith(b"\n"):
        raise EvidenceSupportError("state event ledger lacks its terminal newline")
    lines = raw[:-1].split(b"\n")
    if not lines or len(lines) > MAXIMUM_EVENT_COUNT:
        raise EvidenceSupportError("state event ledger line count is invalid")
    previous_hash: str | None = None
    operations: dict[str, tuple[Any, Any]] = {}
    for line_number, line in enumerate(lines, 1):
        if len(line) + 1 > MAXIMUM_EVENT_BYTES:
            raise EvidenceSupportError(
                f"state event line {line_number} exceeds its line bound"
            )
        event = decode_strict_json_object(
            line,
            label=f"state event line {line_number}",
        )
        stored_hash = event.get("event_hash")
        if not isinstance(stored_hash, str) or len(stored_hash) != 64:
            raise EvidenceSupportError(
                f"state event hash is invalid at line {line_number}"
            )
        unhashed = dict(event)
        del unhashed["event_hash"]
        if stored_hash != event_hash(unhashed):
            raise EvidenceSupportError(
                f"state event hash mismatch at line {line_number}"
            )
        if event.get("previous_hash") != previous_hash:
            raise EvidenceSupportError(
                f"state event chain mismatch at line {line_number}"
            )
        sequence = event.get("sequence")
        if (
            not isinstance(sequence, int)
            or isinstance(sequence, bool)
            or sequence != line_number
        ):
            raise EvidenceSupportError(
                f"state event sequence mismatch at line {line_number}"
            )
        operation_id = event.get("operation_id")
        if operation_id is not None:
            if (
                not isinstance(operation_id, str)
                or OPERATION_IDENTIFIER_PATTERN.fullmatch(operation_id) is None
            ):
                raise EvidenceSupportError(
                    f"state event operation identifier is invalid at line {line_number}"
                )
            request = (event.get("type"), event.get("payload"))
            if operation_id in operations:
                if operations[operation_id] != request:
                    raise EvidenceSupportError(
                        "state operation identifier collides with a different "
                        f"request at line {line_number}"
                    )
                raise EvidenceSupportError(
                    f"state operation identifier is duplicated at line {line_number}"
                )
            operations[operation_id] = request
        previous_hash = stored_hash
    return len(lines), previous_hash


def open_event_ledger(
    state_descriptor: int,
) -> tuple[int, os.stat_result]:
    existed = stat_path_at(state_descriptor, EVENT_FILE_NAME) is not None
    descriptor, metadata = open_regular_at(
        state_descriptor,
        EVENT_FILE_NAME,
        label="state event ledger",
        read_write=True,
        create=True,
    )
    if not existed:
        os.fsync(state_descriptor)
    return descriptor, metadata


def append_event_line(
    state_descriptor: int,
    ledger_descriptor: int,
    path_identity: os.stat_result,
    prior_length: int,
    raw: bytes,
) -> None:
    if prior_length + len(raw) > MAXIMUM_EVENT_LEDGER_BYTES:
        raise EvidenceSupportError(
            f"state event ledger exceeds its {MAXIMUM_EVENT_LEDGER_BYTES}-byte bound"
        )
    require_path_identity(
        state_descriptor,
        EVENT_FILE_NAME,
        path_identity,
        "state event ledger",
    )
    current = os.fstat(ledger_descriptor)
    require_secure_regular(current, "state event ledger")
    if not same_identity(current, path_identity) or current.st_size != prior_length:
        raise EvidenceSupportError("state event ledger changed before append")
    os.lseek(ledger_descriptor, prior_length, os.SEEK_SET)
    write_all(ledger_descriptor, raw, "state event ledger")
    os.fsync(ledger_descriptor)
    final = os.fstat(ledger_descriptor)
    if (
        not same_identity(final, path_identity)
        or final.st_size != prior_length + len(raw)
        or final.st_size > MAXIMUM_EVENT_LEDGER_BYTES
    ):
        raise EvidenceSupportError("state event ledger changed during append")
    require_path_identity(
        state_descriptor,
        EVENT_FILE_NAME,
        final,
        "state event ledger",
    )


def verify_appended_ledger(
    state_descriptor: int,
    ledger_descriptor: int,
    expected: bytes,
) -> os.stat_result:
    identity = os.fstat(ledger_descriptor)
    require_secure_regular(identity, "state event ledger")
    actual = read_bounded_descriptor(
        ledger_descriptor,
        identity,
        label="state event ledger",
        maximum_bytes=MAXIMUM_EVENT_LEDGER_BYTES,
    )
    require_path_identity(
        state_descriptor,
        EVENT_FILE_NAME,
        identity,
        "state event ledger",
    )
    if actual != expected:
        raise EvidenceSupportError("state event ledger content changed during append")
    validate_event_ledger(actual)
    return identity


def prepare_transition(
    state: dict[str, Any],
    event_type: str,
    payload: dict[str, Any],
    ledger_raw: bytes,
    operation_id: str,
) -> tuple[dict[str, Any], bytes, dict[str, Any]]:
    ledger_count, previous_hash = validate_event_ledger(ledger_raw)
    last_sequence = state.get("last_event_sequence", 0)
    if (
        not isinstance(last_sequence, int)
        or isinstance(last_sequence, bool)
        or last_sequence < 0
        or last_sequence != ledger_count
        or last_sequence >= MAXIMUM_EVENT_COUNT
    ):
        raise EvidenceSupportError(
            "run state and bounded event ledger sequence do not match"
        )
    event: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "sequence": last_sequence + 1,
        "event_id": str(uuid.uuid4()),
        "timestamp": now(),
        "type": event_type,
        "payload": payload,
        "operation_id": operation_id,
        "previous_hash": previous_hash,
    }
    event["event_hash"] = event_hash(event)
    event_raw = encoded_event(event)
    if len(ledger_raw) + len(event_raw) > MAXIMUM_EVENT_LEDGER_BYTES:
        raise EvidenceSupportError(
            f"state event ledger exceeds its {MAXIMUM_EVENT_LEDGER_BYTES}-byte bound"
        )
    state["last_event_sequence"] = last_sequence + 1
    encoded_json(
        state,
        label="run state",
        maximum_bytes=MAXIMUM_STATE_JSON_BYTES,
    )
    transaction = {
        "schema_version": SCHEMA_VERSION,
        "prior_ledger_length": len(ledger_raw),
        "prior_ledger_sha256": hashlib.sha256(ledger_raw).hexdigest(),
        "event": event,
        "new_state": state,
    }
    encoded_json(
        transaction,
        label="state transaction",
        maximum_bytes=MAXIMUM_TRANSACTION_BYTES,
    )
    return event, event_raw, transaction


def validate_transaction(
    transaction: dict[str, Any],
) -> tuple[int, str, dict[str, Any], bytes, dict[str, Any]]:
    if set(transaction) != {
        "schema_version",
        "prior_ledger_length",
        "prior_ledger_sha256",
        "event",
        "new_state",
    }:
        raise EvidenceSupportError("state transaction fields are invalid")
    if transaction.get("schema_version") != SCHEMA_VERSION:
        raise EvidenceSupportError("state transaction schema is invalid")
    prior_length = transaction.get("prior_ledger_length")
    if (
        not isinstance(prior_length, int)
        or isinstance(prior_length, bool)
        or prior_length < 0
        or prior_length > MAXIMUM_EVENT_LEDGER_BYTES
    ):
        raise EvidenceSupportError("state transaction ledger length is invalid")
    prior_sha256 = transaction.get("prior_ledger_sha256")
    if (
        not isinstance(prior_sha256, str)
        or len(prior_sha256) != 64
        or any(character not in "0123456789abcdef" for character in prior_sha256)
    ):
        raise EvidenceSupportError("state transaction ledger digest is invalid")
    event = transaction.get("event")
    new_state = transaction.get("new_state")
    if not isinstance(event, dict) or not isinstance(new_state, dict):
        raise EvidenceSupportError("state transaction payload is invalid")
    stored_hash = event.get("event_hash")
    unhashed = dict(event)
    unhashed.pop("event_hash", None)
    if not isinstance(stored_hash, str) or stored_hash != event_hash(unhashed):
        raise EvidenceSupportError("state transaction event hash is invalid")
    pending_operation_id = event.get("operation_id")
    if pending_operation_id is not None and (
        not isinstance(pending_operation_id, str)
        or OPERATION_IDENTIFIER_PATTERN.fullmatch(pending_operation_id) is None
    ):
        raise EvidenceSupportError(
            "state transaction operation identifier is invalid"
        )
    sequence = event.get("sequence")
    if (
        not isinstance(sequence, int)
        or isinstance(sequence, bool)
        or sequence < 1
        or new_state.get("last_event_sequence") != sequence
    ):
        raise EvidenceSupportError("state transaction sequence is invalid")
    event_raw = encoded_event(event)
    encoded_json(
        new_state,
        label="run state",
        maximum_bytes=MAXIMUM_STATE_JSON_BYTES,
    )
    return prior_length, prior_sha256, event, event_raw, new_state


def recover_transaction(state_descriptor: int) -> bool:
    cleanup_staging_file(
        state_descriptor,
        TRANSACTION_STAGING_FILE_NAME,
        label="state transaction staging file",
    )
    cleanup_staging_file(
        state_descriptor,
        STATE_STAGING_FILE_NAME,
        label="run state staging file",
    )
    if stat_path_at(state_descriptor, TRANSACTION_FILE_NAME) is None:
        return False
    transaction = read_json_at(
        state_descriptor,
        TRANSACTION_FILE_NAME,
        label="state transaction",
        maximum_bytes=MAXIMUM_TRANSACTION_BYTES,
    )
    prior_length, prior_sha256, event, event_raw, new_state = validate_transaction(
        transaction
    )
    ledger_descriptor, ledger_identity = open_event_ledger(state_descriptor)
    try:
        ledger_raw = read_bounded_descriptor(
            ledger_descriptor,
            ledger_identity,
            label="state event ledger",
            maximum_bytes=MAXIMUM_EVENT_LEDGER_BYTES,
        )
        require_path_identity(
            state_descriptor,
            EVENT_FILE_NAME,
            ledger_identity,
            "state event ledger",
        )
        if len(ledger_raw) < prior_length:
            raise EvidenceSupportError("state transaction ledger prefix is truncated")
        prior_raw = ledger_raw[:prior_length]
        if hashlib.sha256(prior_raw).hexdigest() != prior_sha256:
            raise EvidenceSupportError("state transaction ledger prefix changed")
        prior_count, prior_hash = validate_event_ledger(prior_raw)
        if event.get("sequence") != prior_count + 1:
            raise EvidenceSupportError("state transaction event sequence is not next")
        if event.get("previous_hash") != prior_hash:
            raise EvidenceSupportError("state transaction event predecessor is invalid")
        suffix = ledger_raw[prior_length:]
        if suffix != event_raw:
            if len(suffix) >= len(event_raw) or not event_raw.startswith(suffix):
                raise EvidenceSupportError("state transaction ledger suffix is invalid")
            os.ftruncate(ledger_descriptor, prior_length)
            os.fsync(ledger_descriptor)
            ledger_identity = os.fstat(ledger_descriptor)
            require_secure_regular(ledger_identity, "state event ledger")
            require_path_identity(
                state_descriptor,
                EVENT_FILE_NAME,
                ledger_identity,
                "state event ledger",
            )
            append_event_line(
                state_descriptor,
                ledger_descriptor,
                ledger_identity,
                prior_length,
                event_raw,
            )
        # The prior process may have completed the write and died before its
        # durability sync. Establish ledger durability on both recovery paths
        # before publishing the matching run state.
        os.fsync(ledger_descriptor)
        final_raw = prior_raw + event_raw
        verify_appended_ledger(
            state_descriptor,
            ledger_descriptor,
            final_raw,
        )
    finally:
        os.close(ledger_descriptor)
    atomic_json_at(
        state_descriptor,
        STATE_FILE_NAME,
        STATE_STAGING_FILE_NAME,
        new_state,
        label="run state",
        maximum_bytes=MAXIMUM_STATE_JSON_BYTES,
    )
    unlink_secure_file_at(
        state_descriptor,
        TRANSACTION_FILE_NAME,
        label="state transaction",
        missing_ok=False,
    )
    return True


def commit_transition(
    state_descriptor: int,
    state: dict[str, Any],
    event_type: str,
    payload: dict[str, Any],
    operation_id: str,
) -> dict[str, Any]:
    if stat_path_at(state_descriptor, TRANSACTION_FILE_NAME) is not None:
        raise EvidenceSupportError("an unrecovered state transaction remains")
    ledger_descriptor, ledger_identity = open_event_ledger(state_descriptor)
    try:
        ledger_raw = read_bounded_descriptor(
            ledger_descriptor,
            ledger_identity,
            label="state event ledger",
            maximum_bytes=MAXIMUM_EVENT_LEDGER_BYTES,
        )
        require_path_identity(
            state_descriptor,
            EVENT_FILE_NAME,
            ledger_identity,
            "state event ledger",
        )
        event, event_raw, transaction = prepare_transition(
            state,
            event_type,
            payload,
            ledger_raw,
            operation_id,
        )
        atomic_json_at(
            state_descriptor,
            TRANSACTION_FILE_NAME,
            TRANSACTION_STAGING_FILE_NAME,
            transaction,
            label="state transaction",
            maximum_bytes=MAXIMUM_TRANSACTION_BYTES,
        )
        append_event_line(
            state_descriptor,
            ledger_descriptor,
            ledger_identity,
            len(ledger_raw),
            event_raw,
        )
        verify_appended_ledger(
            state_descriptor,
            ledger_descriptor,
            ledger_raw + event_raw,
        )
    finally:
        os.close(ledger_descriptor)
    atomic_json_at(
        state_descriptor,
        STATE_FILE_NAME,
        STATE_STAGING_FILE_NAME,
        state,
        label="run state",
        maximum_bytes=MAXIMUM_STATE_JSON_BYTES,
    )
    unlink_secure_file_at(
        state_descriptor,
        TRANSACTION_FILE_NAME,
        label="state transaction",
        missing_ok=False,
    )
    return event


def committed_operation(
    state_descriptor: int,
    operation_id: str,
    event_type: str,
    payload: dict[str, Any],
) -> tuple[bool, int]:
    if stat_path_at(state_descriptor, EVENT_FILE_NAME) is None:
        return False, 0
    ledger_raw = read_bytes_at(
        state_descriptor,
        EVENT_FILE_NAME,
        label="state event ledger",
        maximum_bytes=MAXIMUM_EVENT_LEDGER_BYTES,
    )
    ledger_count, _ = validate_event_ledger(ledger_raw)
    if not ledger_raw:
        return False, ledger_count
    found_matching_request = False
    for line_number, line in enumerate(ledger_raw[:-1].split(b"\n"), 1):
        event = decode_strict_json_object(
            line,
            label=f"state event line {line_number}",
        )
        if event.get("operation_id") != operation_id:
            continue
        if event.get("type") != event_type or event.get("payload") != payload:
            raise EvidenceSupportError(
                "state operation identifier collides with a different request"
            )
        found_matching_request = True
    return found_matching_request, ledger_count

def initial_state(
    repo: Path,
    package: Path,
    budget: BoundedReadBudget,
) -> dict[str, Any]:
    phase_plan = read_json(
        repo,
        package / "plans" / "phases.json",
        label="phase plan",
        maximum_bytes=MAXIMUM_PLAN_JSON_BYTES,
        budget=budget,
    )
    gate_plan = read_json(
        repo,
        package / "plans" / "gates.json",
        label="gate plan",
        maximum_bytes=MAXIMUM_PLAN_JSON_BYTES,
        budget=budget,
    )
    timestamp = now()
    return {
        "schema_version": SCHEMA_VERSION,
        "run_id": str(uuid.uuid4()),
        "status": "active",
        "created_at": timestamp,
        "updated_at": timestamp,
        "repository": repository_state(repo),
        "phases": {p["id"]: {"status": "not_started", "attempts": 0, "last_error": None, "updated_at": None} for p in phase_plan["phases"]},
        "gates": {g["id"]: {"status": "not_started", "evidence_ids": [], "evaluator": None, "operation_id": None, "updated_at": None} for g in gate_plan["gates"]},
        "issues": [],
        "attempts": [],
        "evidence": [],
        "decisions": [],
        "handoffs": [],
        "current_work": None,
        "last_event_sequence": 0,
    }

def require_state_at(
    state_descriptor: int,
    budget: BoundedReadBudget,
) -> dict[str, Any]:
    if stat_path_at(state_descriptor, STATE_FILE_NAME) is None:
        raise SystemExit("Run state is absent; execute statectl.py init")
    return read_json_at(
        state_descriptor,
        STATE_FILE_NAME,
        label="run state",
        maximum_bytes=MAXIMUM_STATE_JSON_BYTES,
        budget=budget,
    )


CANONICAL_COMPLETION_GATES = tuple(f"G{index:02d}" for index in range(13))


def require_gate_operation_identifier(value: Any, gate_identifier: str) -> str:
    if not isinstance(value, str):
        raise EvidenceSupportError(
            f"{gate_identifier} gate result operation identifier is absent"
        )
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as error:
        raise EvidenceSupportError(
            f"{gate_identifier} gate result operation identifier is not a UUID"
        ) from error
    if parsed.version != 4 or str(parsed) != value:
        raise EvidenceSupportError(
            f"{gate_identifier} gate result operation identifier is not canonical UUID-v4"
        )
    return value


def completion_gate_plan(
    repo: Path,
    budget: BoundedReadBudget,
) -> tuple[dict[str, dict[str, Any]], tuple[str, ...]]:
    package, _, _, _ = paths(repo)
    document = read_json(
        repo,
        package / "plans/gates.json",
        label="completion gate plan",
        maximum_bytes=MAXIMUM_PLAN_JSON_BYTES,
        budget=budget,
    )
    required = document.get("completion_requires")
    definitions = document.get("gates")
    if (
        not isinstance(required, list)
        or tuple(required) != CANONICAL_COMPLETION_GATES
        or not isinstance(definitions, list)
        or len(definitions) != len(CANONICAL_COMPLETION_GATES)
    ):
        raise EvidenceSupportError(
            "completion gate plan does not declare the canonical G00-G12 inventory"
        )
    by_identifier: dict[str, dict[str, Any]] = {}
    for index, definition in enumerate(definitions):
        expected = CANONICAL_COMPLETION_GATES[index]
        criteria = definition.get("criteria") if isinstance(definition, dict) else None
        if (
            not isinstance(definition, dict)
            or definition.get("id") != expected
            or expected in by_identifier
            or not isinstance(criteria, list)
            or not criteria
            or len(set(criteria)) != len(criteria)
            or not all(isinstance(item, str) and item for item in criteria)
        ):
            raise EvidenceSupportError(
                f"completion gate plan definition is malformed for {expected}"
            )
        by_identifier[expected] = definition
    return by_identifier, tuple(required)


def load_state_events(
    state_descriptor: int,
) -> dict[str, dict[str, Any]]:
    raw = read_bytes_at(
        state_descriptor,
        EVENT_FILE_NAME,
        label="state event ledger",
        maximum_bytes=MAXIMUM_EVENT_LEDGER_BYTES,
    )
    validate_event_ledger(raw)
    events: dict[str, dict[str, Any]] = {}
    for line_number, line in enumerate(raw[:-1].split(b"\n"), 1):
        event = decode_strict_json_object(
            line,
            label=f"state event line {line_number}",
        )
        operation_id = event.get("operation_id")
        if not isinstance(operation_id, str) or operation_id in events:
            raise EvidenceSupportError(
                "state event ledger has a missing or duplicate operation identifier"
            )
        events[operation_id] = event
    return events


def read_gate_result_raw(
    state_descriptor: int,
    gate_identifier: str,
    budget: BoundedReadBudget,
) -> tuple[bytes, dict[str, Any]]:
    result_directory_descriptor: int | None = None
    try:
        result_directory_descriptor = os.open(
            "gate-results",
            directory_open_flags(),
            dir_fd=state_descriptor,
        )
        require_secure_directory(
            os.fstat(result_directory_descriptor),
            "gate-results directory",
        )
        raw = read_bytes_at(
            result_directory_descriptor,
            f"{gate_identifier}.json",
            label=f"{gate_identifier} gate result",
            maximum_bytes=MAXIMUM_GATE_RESULT_JSON_BYTES,
            budget=budget,
        )
        return raw, decode_strict_json_object(
            raw,
            label=f"{gate_identifier} gate result",
        )
    except OSError as error:
        raise EvidenceSupportError(
            f"{gate_identifier} gate result is unavailable or contains a symlink: {error}"
        ) from error
    finally:
        if result_directory_descriptor is not None:
            os.close(result_directory_descriptor)


def read_gate_artifact_raw(
    state_descriptor: int,
    name: str,
    *,
    label: str,
    budget: BoundedReadBudget,
) -> bytes:
    result_directory_descriptor: int | None = None
    try:
        result_directory_descriptor = os.open(
            "gate-results",
            directory_open_flags(),
            dir_fd=state_descriptor,
        )
        require_secure_directory(
            os.fstat(result_directory_descriptor),
            "gate-results directory",
        )
        return read_bytes_at(
            result_directory_descriptor,
            name,
            label=label,
            maximum_bytes=MAXIMUM_GATE_ARTIFACT_BYTES,
            budget=budget,
        )
    except OSError as error:
        raise EvidenceSupportError(f"{label} is unavailable: {error}") from error
    finally:
        if result_directory_descriptor is not None:
            os.close(result_directory_descriptor)


def require_gate_result_contract(
    repo: Path,
    state_descriptor: int,
    state: dict[str, Any],
    gate_identifier: str,
    definition: dict[str, Any],
    current_head: str,
    current_manifest: dict[str, Any],
    events: dict[str, dict[str, Any]],
    control_budget_value: BoundedReadBudget,
    artifact_budget: BoundedReadBudget,
) -> tuple[dict[str, Any], dict[str, Any]]:
    raw, result = read_gate_result_raw(
        state_descriptor,
        gate_identifier,
        control_budget_value,
    )
    operation_id = require_gate_operation_identifier(
        result.get("operation_id"),
        gate_identifier,
    )
    sequence_before = result.get("state_sequence_before")
    if (
        result.get("schema_version") != 1
        or result.get("gate_id") != gate_identifier
        or result.get("status") != "passed"
        or result.get("finalized") is not True
        or result.get("source_head") != current_head
        or result.get("source_manifest") != current_manifest
        or not isinstance(sequence_before, int)
        or isinstance(sequence_before, bool)
        or sequence_before < 0
        or result.get("notes") != ""
    ):
        raise EvidenceSupportError(
            f"{gate_identifier} gate result does not satisfy the finalized current-source envelope"
        )

    environment = result.get("environment")
    if (
        not isinstance(environment, dict)
        or environment.get("repository") != str(repo)
        or not isinstance(environment.get("platform"), str)
        or not environment.get("platform")
        or not isinstance(environment.get("machine"), str)
        or not environment.get("machine")
    ):
        raise EvidenceSupportError(
            f"{gate_identifier} gate result environment is malformed"
        )
    try:
        started = datetime.fromisoformat(result.get("started_at"))
        ended = datetime.fromisoformat(result.get("ended_at"))
    except (TypeError, ValueError) as error:
        raise EvidenceSupportError(
            f"{gate_identifier} gate result timing is malformed"
        ) from error
    if started.tzinfo is None or ended.tzinfo is None or started > ended:
        raise EvidenceSupportError(
            f"{gate_identifier} gate result timing is malformed"
        )

    criteria = definition["criteria"]
    evaluator = result.get("evaluator")
    criteria_results = (
        evaluator.get("criteria_results") if isinstance(evaluator, dict) else None
    )
    if (
        not isinstance(evaluator, dict)
        or evaluator.get("name") != "forge-gate-handler"
        or evaluator.get("version") != "1"
        or not isinstance(criteria_results, list)
        or len(criteria_results) != len(criteria)
        or any(
            not isinstance(item, dict)
            or item.get("criterion") != criterion
            or item.get("passed") is not True
            or "evidence" not in item
            for item, criterion in zip(criteria_results, criteria)
        )
    ):
        raise EvidenceSupportError(
            f"{gate_identifier} gate result criteria contract is malformed or nonpassing"
        )

    expected_artifacts = (
        ("stdout", f"{gate_identifier}.stdout.txt"),
        ("stderr", f"{gate_identifier}.stderr.txt"),
        ("criteria", f"{gate_identifier}.criteria.json"),
    )
    artifacts = result.get("artifacts")
    if not isinstance(artifacts, list) or len(artifacts) != 3:
        raise EvidenceSupportError(
            f"{gate_identifier} gate result does not bind exactly three runner artifacts"
        )
    artifact_hashes: dict[str, str] = {}
    criteria_document: dict[str, Any] | None = None
    for artifact, (expected_kind, expected_name) in zip(
        artifacts,
        expected_artifacts,
    ):
        expected_path = repo / ".forge-codex/state/gate-results" / expected_name
        if (
            not isinstance(artifact, dict)
            or artifact.get("kind") != expected_kind
            or artifact.get("path") != str(expected_path)
            or not isinstance(artifact.get("sha256"), str)
            or SHA256_PATTERN.fullmatch(artifact["sha256"]) is None
        ):
            raise EvidenceSupportError(
                f"{gate_identifier} gate result has a noncanonical {expected_kind} artifact"
            )
        artifact_raw = read_gate_artifact_raw(
            state_descriptor,
            expected_name,
            label=f"{gate_identifier} {expected_kind} artifact",
            budget=artifact_budget,
        )
        actual_hash = hashlib.sha256(artifact_raw).hexdigest()
        if actual_hash != artifact["sha256"]:
            raise EvidenceSupportError(
                f"{gate_identifier} {expected_kind} artifact hash does not match"
            )
        artifact_hashes[expected_kind] = actual_hash
        if expected_kind == "criteria":
            criteria_document = decode_strict_json_object(
                artifact_raw,
                label=f"{gate_identifier} criteria artifact",
            )
    if (
        not isinstance(criteria_document, dict)
        or criteria_document.get("criteria_results") != criteria_results
    ):
        raise EvidenceSupportError(
            f"{gate_identifier} criteria artifact does not match the gate result evaluator"
        )

    commands = result.get("commands")
    command = commands[0] if isinstance(commands, list) and len(commands) == 1 else None
    if (
        not isinstance(command, dict)
        or command.get("command")
        != str(repo / ".forge-codex/state/gate-handlers" / f"{gate_identifier}.sh")
        or command.get("exit_code") != 0
        or isinstance(command.get("exit_code"), bool)
        or command.get("timed_out") is not False
        or command.get("stdout_sha256") != artifact_hashes["stdout"]
        or command.get("stderr_sha256") != artifact_hashes["stderr"]
    ):
        raise EvidenceSupportError(
            f"{gate_identifier} gate result command contract is malformed or nonpassing"
        )

    gates = state.get("gates")
    item = gates.get(gate_identifier) if isinstance(gates, dict) else None
    canonical_result_path = (
        repo / ".forge-codex/state/gate-results" / f"{gate_identifier}.json"
    )
    expected_evidence = sorted(set(artifact_hashes.values()))
    if (
        not isinstance(item, dict)
        or item.get("status") != "passed"
        or item.get("operation_id") != operation_id
        or item.get("evaluator") != str(canonical_result_path)
        or item.get("evidence_ids") != expected_evidence
    ):
        raise EvidenceSupportError(
            f"{gate_identifier} state does not match its canonical finalized result"
        )
    event = events.get(operation_id)
    expected_payload = {
        "gate": gate_identifier,
        "status": "passed",
        "evidence": [artifact_hashes[kind] for kind, _ in expected_artifacts],
        "evaluator": str(canonical_result_path),
    }
    if (
        not isinstance(event, dict)
        or event.get("type") != "gate_status"
        or event.get("payload") != expected_payload
        or event.get("sequence") != sequence_before + 1
    ):
        raise EvidenceSupportError(
            f"{gate_identifier} gate event does not immediately commit its result snapshot"
        )
    return result, {
        "gate_id": gate_identifier,
        "operation_id": operation_id,
        "sha256": hashlib.sha256(raw).hexdigest(),
        "bytes": len(raw),
        "criteria_document": criteria_document,
        "started": started,
        "ended": ended,
    }


def require_g12_completion_report_contract(
    repo: Path,
    state_descriptor: int,
    state: dict[str, Any],
    current_head: str,
    current_manifest: dict[str, Any],
    g12_result: dict[str, Any],
    g12_binding: dict[str, Any],
    prerequisite_bindings: list[dict[str, Any]],
) -> None:
    report_raw = read_bytes_at(
        state_descriptor,
        "completion-report.json",
        label="completion JSON report",
        maximum_bytes=MAXIMUM_STATE_JSON_BYTES,
    )
    markdown_raw = read_bytes_at(
        state_descriptor,
        "completion-report.md",
        label="completion Markdown report",
        maximum_bytes=MAXIMUM_STATE_JSON_BYTES,
    )
    report = decode_strict_json_object(
        report_raw,
        label="completion JSON report",
    )
    report_bindings = [
        {
            "path": ".forge-codex/state/completion-report.json",
            "sha256": hashlib.sha256(report_raw).hexdigest(),
            "bytes": len(report_raw),
        },
        {
            "path": ".forge-codex/state/completion-report.md",
            "sha256": hashlib.sha256(markdown_raw).hexdigest(),
            "bytes": len(markdown_raw),
        },
    ]
    criteria_document = g12_binding.get("criteria_document")
    if (
        not isinstance(criteria_document, dict)
        or criteria_document.get("valid") is not True
        or criteria_document.get("errors") != []
        or criteria_document.get("report_bindings") != report_bindings
    ):
        raise EvidenceSupportError(
            "G12 criteria do not bind the exact successful completion reports"
        )
    expected_evidence = (
        ".forge-codex/state/completion-report.json sha256="
        f"{report_bindings[0]['sha256']}; "
        ".forge-codex/state/completion-report.md sha256="
        f"{report_bindings[1]['sha256']}"
    )
    evaluator = g12_result.get("evaluator")
    criteria_results = (
        evaluator.get("criteria_results") if isinstance(evaluator, dict) else None
    )
    if not isinstance(criteria_results, list) or any(
        not isinstance(item, dict) or item.get("evidence") != expected_evidence
        for item in criteria_results
    ):
        raise EvidenceSupportError(
            "G12 criteria do not cite the exact completion report digests"
        )

    admission_contract = report.get("admission_contract")
    sequence_before_g12 = g12_result.get("state_sequence_before")
    expected_admission = {
        "schema_version": 1,
        "run_id": state.get("run_id"),
        "repository": str(repo),
        "source_head": current_head,
        "source_manifest": current_manifest,
        "state_sequence_before_g12": sequence_before_g12,
        "prerequisite_gates": list(CANONICAL_COMPLETION_GATES[:-1]),
        "gate_results": prerequisite_bindings,
    }
    if admission_contract != expected_admission:
        raise EvidenceSupportError(
            "completion report admission contract does not bind the current prerequisite results"
        )

    try:
        evaluated_at = datetime.fromisoformat(report.get("evaluated_at"))
    except (TypeError, ValueError) as error:
        raise EvidenceSupportError(
            "completion report evaluation time is malformed"
        ) from error
    if (
        evaluated_at.tzinfo is None
        or evaluated_at < g12_binding["started"]
        or evaluated_at > g12_binding["ended"]
    ):
        raise EvidenceSupportError(
            "completion report was not evaluated during the G12 runner interval"
        )
    finalization = report.get("finalization_gate")
    if (
        report.get("schema_version") != 2
        or report.get("repository") != str(repo)
        or report.get("run_id") != state.get("run_id")
        or report.get("commit") != current_head
        or report.get("passed") is not True
        or report.get("errors") != []
        or not isinstance(finalization, dict)
        or finalization.get("gate_id") != "G12"
        or finalization.get("status") != "eligible_for_finalization"
    ):
        raise EvidenceSupportError(
            "completion report does not carry successful current-release authority"
        )

    checks = report.get("checks")
    if not isinstance(checks, list) or not checks:
        raise EvidenceSupportError("completion report check inventory is absent")
    check_names: set[str] = set()
    for item in checks:
        name = item.get("name") if isinstance(item, dict) else None
        if (
            not isinstance(item, dict)
            or not isinstance(name, str)
            or not name
            or name in check_names
            or item.get("passed") is not True
            or not isinstance(item.get("detail"), str)
        ):
            raise EvidenceSupportError(
                "completion report check inventory is duplicate, malformed, or nonpassing"
            )
        check_names.add(name)
    required_checks = {
        "run-state-valid",
        "package-valid",
        "attribution-clean",
        "secret-scan-clean",
        "current-git-head-valid",
        "current-source-manifest-valid",
        "relevant-source-clean",
        "current-source-identity-stable",
        "source-identity-unchanged-through-evaluation",
        "completion-gate-plan-valid",
        "feature-baseline-valid",
        "findings-resolution-structure",
        "run-state-issues-structure",
        "critical-high-findings-resolved",
        "critical-high-run-state-issues-resolved",
        "autonomous-rollover-mode-proven",
        "supported-api-only",
    }
    for gate_identifier in CANONICAL_COMPLETION_GATES[:-1]:
        required_checks.update(
            {
                f"gate-result-binding:{gate_identifier}",
                f"gate-finalized-result:{gate_identifier}",
                f"gate-operation-pair:{gate_identifier}",
                f"gate-current-source-binding:{gate_identifier}",
                f"gate-command-contract:{gate_identifier}",
                f"gate-criteria-contract:{gate_identifier}",
                f"gate-result-envelope:{gate_identifier}",
                f"gate-artifacts:{gate_identifier}",
            }
        )
        if gate_identifier in {f"G{index:02d}" for index in range(2, 12)}:
            required_checks.add(f"gate-current-release-authority:{gate_identifier}")
    required_checks.add("g10-p10-feature-evidence-binding")
    if check_names != required_checks:
        missing = sorted(required_checks - check_names)
        unexpected = sorted(check_names - required_checks)
        raise EvidenceSupportError(
            "completion report check inventory is not exact; "
            f"missing={missing[:16]!r}; unexpected={unexpected[:16]!r}"
        )


def require_g12_completion_contract(
    repo: Path,
    state_descriptor: int,
    state: dict[str, Any],
    expected_operation_id: str,
) -> None:
    """Require the exact durable G12 result/state pair before completion."""

    expected_operation_id = require_gate_operation_identifier(
        expected_operation_id,
        "G12",
    )
    gate_budget = control_budget()
    definitions, required_gate_ids = completion_gate_plan(repo, gate_budget)
    gates = state.get("gates")
    if (
        not isinstance(gates, dict)
        or tuple(gates) != required_gate_ids
        or set(gates) != set(required_gate_ids)
    ):
        raise EvidenceSupportError("completion gate state is absent or malformed")
    malformed_gates = [
        identifier
        for identifier, item in gates.items()
        if not isinstance(identifier, str)
        or not isinstance(item, dict)
        or item.get("status") not in {
            "not_started",
            "running",
            "passed",
            "failed",
            "blocked_dependency",
            "blocked_environment",
            "retry_scheduled",
        }
    ]
    if malformed_gates:
        raise EvidenceSupportError("completion gate state is malformed")
    nonpassing_gates = sorted(
        identifier
        for identifier, item in gates.items()
        if item.get("status") != "passed"
    )
    if nonpassing_gates:
        raise EvidenceSupportError(
            "completion requires every gate to remain passed: "
            + ", ".join(nonpassing_gates[:32])
        )
    issues = state.get("issues")
    if not isinstance(issues, list):
        raise EvidenceSupportError("run-state issue ledger is malformed")
    blocking_issues: list[str] = []
    issue_identifiers: set[str] = set()
    for item in issues:
        identifier = item.get("id") if isinstance(item, dict) else None
        if (
            not isinstance(item, dict)
            or not isinstance(identifier, str)
            or not identifier
            or identifier in issue_identifiers
            or item.get("severity") not in {"Critical", "High", "Medium", "Low"}
            or item.get("status")
            not in {"open", "patching", "validating", "resolved", "deferred"}
        ):
            raise EvidenceSupportError("run-state issue ledger is malformed")
        issue_identifiers.add(identifier)
        if (
            item.get("severity") in {"Critical", "High"}
            and item.get("status") != "resolved"
        ):
            blocking_issues.append(identifier)
    if blocking_issues:
        raise EvidenceSupportError(
            "completion has unresolved Critical/High run-state issues: "
            + ", ".join(sorted(blocking_issues)[:32])
        )

    current_head = current_git_head(repo)
    if current_head is None:
        raise EvidenceSupportError("completion Git HEAD is unavailable or malformed")
    current_manifest = source_manifest(repo)
    events = load_state_events(state_descriptor)
    artifact_budget = BoundedReadBudget(
        MAXIMUM_GATE_ARTIFACT_AGGREGATE_BYTES,
        "completion gate runner artifacts",
    )
    prerequisite_bindings: list[dict[str, Any]] = []
    validated_results: dict[str, dict[str, Any]] = {}
    validated_bindings: dict[str, dict[str, Any]] = {}
    for gate_identifier in required_gate_ids:
        gate_result, gate_binding = require_gate_result_contract(
            repo,
            state_descriptor,
            state,
            gate_identifier,
            definitions[gate_identifier],
            current_head,
            current_manifest,
            events,
            gate_budget,
            artifact_budget,
        )
        validated_results[gate_identifier] = gate_result
        validated_bindings[gate_identifier] = gate_binding
        if gate_identifier == "G10":
            criteria_document = gate_binding.get("criteria_document")
            if not isinstance(criteria_document, dict) or set(criteria_document) != {
                "criteria_results",
                "valid",
                "errors",
                "p10_feature_binding",
            }:
                raise EvidenceSupportError(
                    "G10 criteria has no exact P10 feature binding"
                )
            try:
                from p10_feature_evidence import validate_p10_feature_binding
            except ImportError as error:
                raise EvidenceSupportError(
                    f"P10 feature binding validator is unavailable: {error}"
                ) from error
            binding_failures = validate_p10_feature_binding(
                repo,
                criteria_document.get("p10_feature_binding"),
                current_manifest=current_manifest,
                current_git_head=current_head,
                ledger_evidence_ids={
                    item
                    for item in state.get("evidence", [])
                    if isinstance(item, str)
                },
            )
            if binding_failures:
                raise EvidenceSupportError(
                    "G10 P10 feature binding is stale or invalid: "
                    + "; ".join(binding_failures[:8])
                )
        if gate_identifier != "G12":
            prerequisite_bindings.append(
                {
                    key: gate_binding[key]
                    for key in ("gate_id", "operation_id", "sha256", "bytes")
                }
            )
    if validated_results["G12"].get("operation_id") != expected_operation_id:
        raise EvidenceSupportError(
            "G12 gate result operation identifier does not match the expected operation"
        )
    require_g12_completion_report_contract(
        repo,
        state_descriptor,
        state,
        current_head,
        current_manifest,
        validated_results["G12"],
        validated_bindings["G12"],
        prerequisite_bindings,
    )
    gate_state = gates.get("G12") if isinstance(gates, dict) else None
    if not isinstance(gate_state, dict):
        raise EvidenceSupportError("G12 state is absent")
    canonical_result_path = (
        repo / ".forge-codex/state/gate-results/G12.json"
    )
    if gate_state.get("status") != "passed":
        raise EvidenceSupportError("G12 state is not passed")
    if gate_state.get("operation_id") != expected_operation_id:
        raise EvidenceSupportError(
            "G12 state operation identifier does not match the expected operation"
        )
    if gate_state.get("evaluator") != str(canonical_result_path):
        raise EvidenceSupportError(
            "G12 state evaluator is not the canonical gate result path"
        )

    result_directory_descriptor: int | None = None
    result_descriptor: int | None = None
    try:
        result_directory_descriptor = os.open(
            "gate-results",
            directory_open_flags(),
            dir_fd=state_descriptor,
        )
        result_directory_identity = os.fstat(result_directory_descriptor)
        require_secure_directory(
            result_directory_identity,
            "gate-results directory",
        )
        result_descriptor, result_identity = open_regular_at(
            result_directory_descriptor,
            "G12.json",
            label="G12 gate result",
            read_write=False,
        )
        raw = read_bounded_descriptor(
            result_descriptor,
            result_identity,
            label="G12 gate result",
            maximum_bytes=MAXIMUM_GATE_RESULT_JSON_BYTES,
        )
        result = decode_strict_json_object(raw, label="G12 gate result")
        if result.get("gate_id") != "G12":
            raise EvidenceSupportError("G12 gate result has the wrong gate identifier")
        if result.get("status") != "passed":
            raise EvidenceSupportError("G12 gate result is not passed")
        if result.get("finalized") is not True:
            raise EvidenceSupportError("G12 gate result is not finalized")
        if result.get("operation_id") != expected_operation_id:
            raise EvidenceSupportError(
                "G12 gate result operation identifier does not match the expected operation"
            )
        sequence_before = result.get("state_sequence_before")
        current_sequence = state.get("last_event_sequence")
        if (
            not isinstance(sequence_before, int)
            or isinstance(sequence_before, bool)
            or sequence_before < 0
        ):
            raise EvidenceSupportError(
                "G12 gate result state sequence is malformed"
            )
        expected_current_sequence = (
            sequence_before + 1
        )
        if state.get("status") == "complete":
            authority = state.get("completion_authority")
            status_operation_id = (
                authority.get("status_operation_id")
                if isinstance(authority, dict)
                else None
            )
            status_event = events.get(status_operation_id)
            if (
                not isinstance(authority, dict)
                or authority
                != {
                    "schema_version": 1,
                    "g12_operation_id": expected_operation_id,
                    "status_operation_id": status_operation_id,
                }
                or not isinstance(status_operation_id, str)
                or OPERATION_IDENTIFIER_PATTERN.fullmatch(status_operation_id) is None
                or not isinstance(status_event, dict)
                or status_event.get("type") != "run_status"
                or status_event.get("payload")
                != {
                    "status": "complete",
                    "expected_g12_operation_id": expected_operation_id,
                }
                or status_event.get("sequence") != sequence_before + 2
            ):
                raise EvidenceSupportError(
                    "completed run does not retain its exact final status transaction"
                )
            expected_current_sequence = sequence_before + 2
        elif state.get("completion_authority") is not None:
            raise EvidenceSupportError(
                "noncomplete run retains an invalid completion authority"
            )
        if (
            not isinstance(sequence_before, int)
            or isinstance(sequence_before, bool)
            or sequence_before < 0
            or not isinstance(current_sequence, int)
            or isinstance(current_sequence, bool)
            or current_sequence != expected_current_sequence
        ):
            raise EvidenceSupportError(
                "run state changed after the G12 evaluation snapshot"
            )
        current_head = current_git_head(repo)
        if current_head is None or result.get("source_head") != current_head:
            raise EvidenceSupportError(
                "G12 gate result does not match the current Git HEAD"
            )
        current_manifest = source_manifest(repo)
        if result.get("source_manifest") != current_manifest:
            raise EvidenceSupportError(
                "G12 gate result does not match the current source manifest"
            )
        source_status_commands = (
            [
                "/usr/bin/git",
                "status",
                "--porcelain=v1",
                "-z",
                "--untracked-files=all",
                "--",
                ".",
                ":(exclude).forge-codex/state",
                ":(exclude).forge-codex/state/**",
                ":(exclude).forge-codex/evidence",
                ":(exclude).forge-codex/evidence/**",
            ],
            [
                "/usr/bin/git",
                "status",
                "--porcelain=v1",
                "-z",
                "--untracked-files=all",
                "--",
                ".forge-codex/state/gate-handlers",
            ],
        )
        for index, command in enumerate(source_status_commands, 1):
            return_code, stdout, stderr = run_bounded_readonly_command(
                repo,
                f"completion source status {index}",
                command,
                timeout_seconds=60.0,
                maximum_output_bytes=MAXIMUM_REPOSITORY_STATUS_BYTES,
            )
            if return_code != 0 or stdout or stderr:
                raise EvidenceSupportError(
                    "completion source is dirty or its Git status is unavailable"
                )
        verification_raw = read_bounded_descriptor(
            result_descriptor,
            result_identity,
            label="G12 gate result",
            maximum_bytes=MAXIMUM_GATE_RESULT_JSON_BYTES,
        )
        if verification_raw != raw:
            raise EvidenceSupportError(
                "G12 gate result changed during completion verification"
            )
        require_path_identity(
            result_directory_descriptor,
            "G12.json",
            result_identity,
            "G12 gate result",
        )
        require_directory_identity(
            os.stat(
                "gate-results",
                dir_fd=state_descriptor,
                follow_symlinks=False,
            ),
            result_directory_identity,
            "gate-results directory",
        )
    except OSError as error:
        raise EvidenceSupportError(
            f"G12 gate result is unavailable or contains a symlink: {error}"
        ) from error
    finally:
        if result_descriptor is not None:
            os.close(result_descriptor)
        if result_directory_descriptor is not None:
            os.close(result_directory_descriptor)

def mutate(
    repo: Path,
    event_type: str,
    payload: dict[str, Any],
    fn,
    *,
    operation_id: str | None = None,
    precondition=None,
) -> dict[str, Any]:
    normalized_operation_id = operation_identifier(operation_id)
    with locked_state_directory(repo, create=False) as state_descriptor:
        recover_transaction(state_descriptor)
        state = require_state_at(state_descriptor, control_budget())
        already_committed, ledger_count = committed_operation(
            state_descriptor,
            normalized_operation_id,
            event_type,
            payload,
        )
        state_sequence = state.get("last_event_sequence")
        if (
            not isinstance(state_sequence, int)
            or isinstance(state_sequence, bool)
            or state_sequence != ledger_count
        ):
            raise EvidenceSupportError("run state and event ledger sequence do not match")
        if already_committed:
            if precondition is not None:
                precondition(state, state_descriptor)
            return state
        if precondition is not None:
            precondition(state, state_descriptor)
        # Completion is authorized against one exact state snapshot. Any new
        # mutation other than the status transition itself invalidates that
        # snapshot and requires G12 to be rerun.
        if state.get("status") == "complete" and event_type != "run_status":
            state["status"] = "active"
            state.pop("completion_authority", None)
        fn(state)
        state["updated_at"] = now()
        state["repository"] = repository_state(repo)
        commit_transition(
            state_descriptor,
            state,
            event_type,
            payload,
            normalized_operation_id,
        )
        return state

def cmd_init(args) -> int:
    repo = locate_repo(args.repo)
    package, state_path, _, _ = paths(repo)
    with locked_state_directory(repo, create=True) as state_descriptor:
        recover_transaction(state_descriptor)
        if stat_path_at(state_descriptor, STATE_FILE_NAME) is not None:
            state = require_state_at(state_descriptor, control_budget())
            print(json.dumps({"state": str(state_path), "run_id": state["run_id"], "status": state["status"]}, indent=2))
            return 0
        state = initial_state(repo, package, control_budget())
        commit_transition(
            state_descriptor,
            state,
            "run_initialized",
            {"repository": str(repo)},
            operation_identifier(None),
        )
    print(json.dumps({"state": str(state_path), "run_id": state["run_id"], "status": state["status"]}, indent=2))
    return 0

def cmd_show(args) -> int:
    repo = locate_repo(args.repo)
    _, state_path, _, _ = paths(repo)
    with locked_state_directory(repo, create=False) as state_descriptor:
        recover_transaction(state_descriptor)
        state = require_state_at(state_descriptor, control_budget())
        if state.get("status") == "complete":
            authority = state.get("completion_authority")
            expected_g12_operation_id = (
                authority.get("g12_operation_id")
                if isinstance(authority, dict)
                else ""
            )
            require_g12_completion_contract(
                repo,
                state_descriptor,
                state,
                expected_g12_operation_id,
            )
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
        raw_payload = args.payload.encode("utf-8", errors="strict")
        if len(raw_payload) > MAXIMUM_EVENT_BYTES:
            raise EvidenceSupportError("event payload exceeds its byte bound")
        payload = decode_strict_json_object(raw_payload, label="event payload")
    except (EvidenceSupportError, UnicodeError) as error:
        raise SystemExit(f"--payload must be a bounded JSON object: {error}") from error
    mutate(
        repo,
        args.type,
        payload,
        lambda state: None,
        operation_id=args.operation_id,
    )
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
    mutate(
        repo,
        "phase_status",
        {"phase":args.phase,"status":args.status,"error":args.error},
        apply,
        operation_id=args.operation_id,
    )
    return 0

def cmd_gate(args) -> int:
    repo = locate_repo(args.repo)
    allowed = {"not_started","running","passed","failed","blocked_dependency","blocked_environment","retry_scheduled"}
    if args.status not in allowed:
        raise SystemExit(f"Invalid gate status: {args.status}")
    evidence_ids = args.evidence or []
    gate_operation_id = operation_identifier(args.operation_id)
    def apply(state):
        if args.gate not in state["gates"]:
            raise SystemExit(f"Unknown gate: {args.gate}")
        item = state["gates"][args.gate]
        item["status"] = args.status
        item["evidence_ids"] = sorted(set(evidence_ids))
        item["evaluator"] = args.evaluator
        item["operation_id"] = gate_operation_id
        item["updated_at"] = now()
        state["evidence"] = sorted(set(state.get("evidence", []) + evidence_ids))
        # Any newly committed gate operation supersedes the exact G12/result
        # set that authorized completion. Idempotent retries return before this
        # mutation, so every operation reaching this point invalidates it.
        if state.get("status") == "complete":
            state["status"] = "active"
            state.pop("completion_authority", None)
    mutate(
        repo,
        "gate_status",
        {"gate":args.gate,"status":args.status,"evidence":evidence_ids,"evaluator":args.evaluator},
        apply,
        operation_id=gate_operation_id,
    )
    return 0

def cmd_attempt(args) -> int:
    repo = locate_repo(args.repo)
    allowed = {"progress","no_progress","transient_failure","blocked","success"}
    if args.outcome not in allowed:
        raise SystemExit(f"Invalid outcome: {args.outcome}")
    attempt_operation_id = operation_identifier(args.operation_id)
    def apply(state):
        prior = [a for a in state["attempts"] if a.get("work_id") == args.work]
        state["attempts"].append({
            "operation_id": attempt_operation_id,
            "work_id": args.work,
            "attempt": len(prior) + 1,
            "outcome": args.outcome,
            "signature": args.signature,
            "timestamp": now(),
        })
    mutate(
        repo,
        "work_attempt",
        {"work":args.work,"outcome":args.outcome,"signature":args.signature},
        apply,
        operation_id=attempt_operation_id,
    )
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
    mutate(
        repo,
        "issue_updated",
        event_payload,
        apply,
        operation_id=args.operation_id,
    )
    return 0

def cmd_reference(args) -> int:
    repo = locate_repo(args.repo)
    if args.kind not in {"evidence","decisions","handoffs"}:
        raise SystemExit("Unsupported reference kind")
    def apply(state):
        state[args.kind] = sorted(set(state.get(args.kind, []) + [args.value]))
    mutate(
        repo,
        "reference_added",
        {"kind":args.kind,"value":args.value},
        apply,
        operation_id=args.operation_id,
    )
    return 0

def cmd_status(args) -> int:
    repo = locate_repo(args.repo)
    allowed = {"active","complete","blocked_environment","fatal_invariant"}
    if args.status not in allowed:
        raise SystemExit("Invalid run status")
    expected_g12_operation_id = args.expected_g12_operation_id
    if args.status == "complete":
        if expected_g12_operation_id is None:
            raise EvidenceSupportError(
                "status complete requires --expected-g12-operation-id"
            )
        expected_g12_operation_id = require_gate_operation_identifier(
            expected_g12_operation_id,
            "G12",
        )
    elif expected_g12_operation_id is not None:
        raise EvidenceSupportError(
            "--expected-g12-operation-id is valid only for status complete"
        )
    status_operation_id = operation_identifier(args.operation_id)
    def apply(state):
        state["status"] = args.status
        if args.status == "complete":
            state["completion_authority"] = {
                "schema_version": 1,
                "g12_operation_id": expected_g12_operation_id,
                "status_operation_id": status_operation_id,
            }
        else:
            state.pop("completion_authority", None)
    payload = {"status": args.status}
    if expected_g12_operation_id is not None:
        payload["expected_g12_operation_id"] = expected_g12_operation_id
    def completion_precondition(state, state_descriptor):
        if expected_g12_operation_id is None:
            return
        require_g12_completion_contract(
            repo,
            state_descriptor,
            state,
            expected_g12_operation_id,
        )
        if state.get("status") == "complete":
            authority = state.get("completion_authority")
            if (
                not isinstance(authority, dict)
                or authority.get("status_operation_id") != status_operation_id
            ):
                raise EvidenceSupportError(
                    "completed run accepts only the exact idempotent final status operation"
                )
    mutate(
        repo,
        "run_status",
        payload,
        apply,
        operation_id=status_operation_id,
        precondition=(completion_precondition if expected_g12_operation_id is not None else None),
    )
    return 0

def cmd_validate(args) -> int:
    repo = locate_repo(args.repo)
    package, state_path, _, _ = paths(repo)
    with locked_state_directory(repo, create=False) as state_descriptor:
        recover_transaction(state_descriptor)
        budget = control_budget()
        state = require_state_at(state_descriptor, budget)
        errors = []
        if state.get("schema_version") != SCHEMA_VERSION:
            errors.append("unsupported state schema")
        phase_plan = read_json(
            repo,
            package / "plans" / "phases.json",
            label="phase plan",
            maximum_bytes=MAXIMUM_PLAN_JSON_BYTES,
            budget=budget,
        )
        gate_plan = read_json(
            repo,
            package / "plans" / "gates.json",
            label="gate plan",
            maximum_bytes=MAXIMUM_PLAN_JSON_BYTES,
            budget=budget,
        )
        phase_ids = {p["id"] for p in phase_plan["phases"]}
        gate_ids = {g["id"] for g in gate_plan["gates"]}
        if set(state.get("phases",{})) != phase_ids:
            errors.append("phase keys do not match plan")
        if set(state.get("gates",{})) != gate_ids:
            errors.append("gate keys do not match plan")
        ledger_raw = b""
        ledger_count = 0
        if stat_path_at(state_descriptor, EVENT_FILE_NAME) is not None:
            ledger_raw = read_bytes_at(
                state_descriptor,
                EVENT_FILE_NAME,
                label="state event ledger",
                maximum_bytes=MAXIMUM_EVENT_LEDGER_BYTES,
            )
        try:
            ledger_count, _ = validate_event_ledger(ledger_raw)
        except EvidenceSupportError as error:
            errors.append(str(error))
        state_sequence = state.get("last_event_sequence")
        if (
            not isinstance(state_sequence, int)
            or isinstance(state_sequence, bool)
            or state_sequence != ledger_count
        ):
            errors.append("state/event sequence mismatch")
        if state.get("status") == "complete":
            authority = state.get("completion_authority")
            expected_g12_operation_id = (
                authority.get("g12_operation_id")
                if isinstance(authority, dict)
                else ""
            )
            try:
                require_g12_completion_contract(
                    repo,
                    state_descriptor,
                    state,
                    expected_g12_operation_id,
                )
            except EvidenceSupportError as error:
                errors.append(f"completion authority is stale or invalid: {error}")
    result = {"valid": not errors, "errors": errors, "state": str(state_path)}
    print(json.dumps(result, indent=2))
    return 0 if not errors else 1

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("init"); p.set_defaults(func=cmd_init)
    p = sub.add_parser("show"); p.add_argument("--compact", action="store_true"); p.set_defaults(func=cmd_show)
    p = sub.add_parser("event"); p.add_argument("type"); p.add_argument("--payload", default="{}"); p.add_argument("--operation-id"); p.set_defaults(func=cmd_event)
    p = sub.add_parser("phase"); p.add_argument("phase"); p.add_argument("status"); p.add_argument("--error"); p.add_argument("--operation-id"); p.set_defaults(func=cmd_phase)
    p = sub.add_parser("gate"); p.add_argument("gate"); p.add_argument("status"); p.add_argument("--evidence", action="append"); p.add_argument("--evaluator"); p.add_argument("--operation-id"); p.set_defaults(func=cmd_gate)
    p = sub.add_parser("attempt"); p.add_argument("work"); p.add_argument("outcome"); p.add_argument("--operation-id"); p.add_argument("--signature"); p.set_defaults(func=cmd_attempt)
    p = sub.add_parser("issue")
    p.add_argument("id")
    p.add_argument("--title")
    p.add_argument("--status", choices=["open","patching","validating","resolved","deferred"])
    p.add_argument("--severity", choices=["Critical","High","Medium","Low"])
    p.add_argument("--evidence-class", choices=["E0","E1","E2","E3"])
    p.add_argument("--path")
    p.add_argument("--notes")
    p.add_argument("--operation-id")
    p.set_defaults(func=cmd_issue)
    p = sub.add_parser("reference"); p.add_argument("kind"); p.add_argument("value"); p.add_argument("--operation-id"); p.set_defaults(func=cmd_reference)
    p = sub.add_parser("status"); p.add_argument("status"); p.add_argument("--operation-id"); p.add_argument("--expected-g12-operation-id"); p.set_defaults(func=cmd_status)
    p = sub.add_parser("validate"); p.set_defaults(func=cmd_validate)
    return parser

def main() -> int:
    parser = build_parser()
    arguments = parser.parse_args()
    try:
        return arguments.func(arguments)
    except EvidenceSupportError as error:
        print(f"state control failed closed: {error}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    raise SystemExit(main())
