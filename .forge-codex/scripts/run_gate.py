#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import math
import os
import platform
import re
import shlex
import stat
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from evidence_support import (
    BoundedCommandError,
    BoundedReadBudget,
    EvidenceSupportError,
    MAXIMUM_QUALIFICATION_ARTIFACT_BYTES,
    current_git_head,
    decode_strict_json_object,
    load_bounded_repository_json_object,
    read_bounded_repository_bytes,
    run_bounded_readonly_command,
    source_manifest,
)


MAXIMUM_GATE_OUTPUT_BYTES = 64 * 1024 * 1024
MAXIMUM_GATE_HANDLER_BYTES = 1024 * 1024
MAXIMUM_GATE_RESULT_JSON_BYTES = 1024 * 1024
MAXIMUM_GATE_JSON_AGGREGATE_BYTES = 64 * 1024 * 1024
MAXIMUM_GATE_LOCK_WAIT_SECONDS = 30.0
MAXIMUM_STATE_CONTROL_SECONDS = 45.0
MAXIMUM_STATE_CONTROL_OUTPUT_BYTES = 64 * 1024
MAXIMUM_STATE_CONTROL_DIAGNOSTIC_BYTES = 4096
GATE_IDENTIFIER_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def locate_repo(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit).resolve()
    path = Path.cwd().resolve()
    for candidate in (path, *path.parents):
        if (candidate / ".forge-codex").is_dir():
            return candidate
    raise SystemExit("repository not found")


def validate_gate_identifier(value: str) -> str:
    if GATE_IDENTIFIER_PATTERN.fullmatch(value) is None:
        raise SystemExit("invalid gate identifier")
    return value


def capture_source_identity(repository: Path) -> dict[str, object]:
    """Capture the bounded content manifest and Git identity for one gate run."""

    source_head = current_git_head(repository)
    if source_head is None:
        raise EvidenceSupportError(
            "source Git HEAD is unavailable or invalid"
        )
    return {
        "source_head": source_head,
        "source_manifest": source_manifest(repository),
    }


def current_state_sequence(repository: Path) -> int | None:
    """Read the pre-gate state sequence used to fence G12 finalization."""

    try:
        state = load_bounded_repository_json_object(
            repository,
            ".forge-codex/state/run-state.json",
            label="pre-gate run state",
            maximum_bytes=MAXIMUM_QUALIFICATION_ARTIFACT_BYTES,
            budget=BoundedReadBudget(
                MAXIMUM_QUALIFICATION_ARTIFACT_BYTES,
                "pre-gate run state",
            ),
            require_owner_controlled=True,
        )
    except EvidenceSupportError:
        return None
    sequence = state.get("last_event_sequence")
    if (
        not isinstance(sequence, int)
        or isinstance(sequence, bool)
        or sequence < 0
    ):
        return None
    return sequence


def directory_open_flags() -> int:
    return (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_DIRECTORY", 0)
    )


def require_secure_directory(metadata: os.stat_result, label: str) -> None:
    if not stat.S_ISDIR(metadata.st_mode):
        raise EvidenceSupportError(f"{label} is not a directory")
    if metadata.st_uid != os.geteuid():
        raise EvidenceSupportError(f"{label} is not owned by the current user")
    if metadata.st_mode & 0o022:
        raise EvidenceSupportError(f"{label} is group- or world-writable")


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


def regular_snapshot(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def stat_path_at(directory_descriptor: int, name: str) -> os.stat_result | None:
    try:
        return os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return None


def require_artifact_path(
    directory_descriptor: int,
    name: str,
    *,
    label: str,
) -> os.stat_result | None:
    metadata = stat_path_at(directory_descriptor, name)
    if metadata is not None:
        require_secure_regular(metadata, label)
    return metadata


def require_path_identity(
    directory_descriptor: int,
    name: str,
    expected: os.stat_result,
    *,
    label: str,
) -> None:
    current = require_artifact_path(
        directory_descriptor,
        name,
        label=label,
    )
    if current is None or not same_identity(current, expected):
        raise EvidenceSupportError(f"{label} pathname identity changed")


def require_directory_path_identity(
    directory_descriptor: int,
    name: str,
    expected: os.stat_result,
    *,
    label: str,
) -> None:
    try:
        current = os.stat(
            name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
    except OSError as error:
        raise EvidenceSupportError(f"{label} pathname identity changed: {error}") from error
    require_secure_directory(current, label)
    if not same_identity(current, expected):
        raise EvidenceSupportError(f"{label} pathname identity changed")


class GateResultDirectory:
    def __init__(
        self,
        repository: Path,
        root_descriptor: int,
        package_descriptor: int,
        state_descriptor: int,
        result_descriptor: int,
    ) -> None:
        self.repository = repository
        self.root_descriptor = root_descriptor
        self.package_descriptor = package_descriptor
        self.state_descriptor = state_descriptor
        self.descriptor = result_descriptor
        self.root_identity = os.fstat(root_descriptor)
        self.package_identity = os.fstat(package_descriptor)
        self.state_identity = os.fstat(state_descriptor)
        self.result_identity = os.fstat(result_descriptor)

    def validate(self) -> None:
        try:
            repository_current = os.stat(self.repository, follow_symlinks=False)
        except OSError as error:
            raise EvidenceSupportError(
                f"repository root pathname identity changed: {error}"
            ) from error
        require_secure_directory(repository_current, "repository root")
        if not same_identity(repository_current, self.root_identity):
            raise EvidenceSupportError("repository root pathname identity changed")
        require_directory_path_identity(
            self.root_descriptor,
            ".forge-codex",
            self.package_identity,
            label=".forge-codex directory",
        )
        require_directory_path_identity(
            self.package_descriptor,
            "state",
            self.state_identity,
            label="state directory",
        )
        require_directory_path_identity(
            self.state_descriptor,
            "gate-results",
            self.result_identity,
            label="gate-results directory",
        )


@contextmanager
def open_gate_result_directory(repository: Path):
    descriptors: list[int] = []
    flags = directory_open_flags()
    try:
        root_descriptor = os.open(repository, flags)
        descriptors.append(root_descriptor)
        require_secure_directory(os.fstat(root_descriptor), "repository root")

        package_descriptor = os.open(
            ".forge-codex",
            flags,
            dir_fd=root_descriptor,
        )
        descriptors.append(package_descriptor)
        require_secure_directory(
            os.fstat(package_descriptor),
            ".forge-codex directory",
        )

        state_descriptor = os.open(
            "state",
            flags,
            dir_fd=package_descriptor,
        )
        descriptors.append(state_descriptor)
        require_secure_directory(os.fstat(state_descriptor), "state directory")

        try:
            result_descriptor = os.open(
                "gate-results",
                flags,
                dir_fd=state_descriptor,
            )
        except FileNotFoundError:
            os.mkdir("gate-results", mode=0o700, dir_fd=state_descriptor)
            os.fsync(state_descriptor)
            result_descriptor = os.open(
                "gate-results",
                flags,
                dir_fd=state_descriptor,
            )
        descriptors.append(result_descriptor)
        require_secure_directory(
            os.fstat(result_descriptor),
            "gate-results directory",
        )
        opened = GateResultDirectory(
            repository,
            root_descriptor,
            package_descriptor,
            state_descriptor,
            result_descriptor,
        )
        yield opened
    except OSError as error:
        raise EvidenceSupportError(
            "gate-results path is unavailable or contains a symlink: "
            f"{error}"
        ) from error
    finally:
        for descriptor in reversed(descriptors):
            try:
                os.close(descriptor)
            except OSError:
                pass


def write_all(descriptor: int, data: bytes) -> None:
    offset = 0
    while offset < len(data):
        try:
            written = os.write(descriptor, data[offset:])
        except InterruptedError:
            continue
        if written <= 0:
            raise EvidenceSupportError("gate artifact write made no progress")
        offset += written


def atomic_write_bytes_at(
    directory_descriptor: int,
    name: str,
    data: bytes,
    *,
    label: str,
) -> None:
    """Durably replace one validated artifact within the opened result directory."""

    original = require_artifact_path(
        directory_descriptor,
        name,
        label=label,
    )
    temporary_name = f".{name}.{uuid.uuid4().hex}.tmp"
    temporary_descriptor: int | None = None
    temporary_metadata: os.stat_result | None = None
    try:
        temporary_descriptor = os.open(
            temporary_name,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=directory_descriptor,
        )
        write_all(temporary_descriptor, data)
        os.fsync(temporary_descriptor)
        temporary_metadata = os.fstat(temporary_descriptor)
        require_secure_regular(temporary_metadata, f"temporary {label}")

        current = require_artifact_path(
            directory_descriptor,
            name,
            label=label,
        )
        if (original is None) != (current is None) or (
            original is not None
            and current is not None
            and not same_identity(original, current)
        ):
            raise EvidenceSupportError(f"{label} pathname identity changed")

        os.replace(
            temporary_name,
            name,
            src_dir_fd=directory_descriptor,
            dst_dir_fd=directory_descriptor,
        )
        os.fsync(directory_descriptor)
        require_path_identity(
            directory_descriptor,
            name,
            temporary_metadata,
            label=label,
        )
    except OSError as error:
        raise EvidenceSupportError(f"cannot durably write {label}: {error}") from error
    finally:
        if temporary_descriptor is not None:
            os.close(temporary_descriptor)
        try:
            os.unlink(temporary_name, dir_fd=directory_descriptor)
        except FileNotFoundError:
            pass


def atomic_write_json_at(
    directory_descriptor: int,
    name: str,
    value: dict[str, object],
    *,
    label: str,
) -> None:
    try:
        encoded = (
            json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n"
        ).encode("utf-8")
    except (TypeError, ValueError, UnicodeError) as error:
        raise EvidenceSupportError(
            f"gate result is not finite UTF-8 JSON: {error}"
        ) from error
    if len(encoded) > MAXIMUM_GATE_RESULT_JSON_BYTES:
        raise EvidenceSupportError(
            "gate result exceeds its 1048576-byte serialization bound"
        )
    atomic_write_bytes_at(
        directory_descriptor,
        name,
        encoded,
        label=label,
    )


def durable_unlink_at(
    directory_descriptor: int,
    name: str,
    *,
    label: str,
) -> None:
    metadata = require_artifact_path(
        directory_descriptor,
        name,
        label=label,
    )
    if metadata is None:
        return
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0),
            dir_fd=directory_descriptor,
        )
        try:
            opened = os.fstat(descriptor)
            require_secure_regular(opened, label)
            if not same_identity(metadata, opened):
                raise EvidenceSupportError(f"{label} pathname identity changed")
            require_path_identity(
                directory_descriptor,
                name,
                opened,
                label=label,
            )
            os.unlink(name, dir_fd=directory_descriptor)
        finally:
            os.close(descriptor)
        os.fsync(directory_descriptor)
    except OSError as error:
        raise EvidenceSupportError(
            f"cannot remove stale {label}: {error}"
        ) from error


def read_bounded_artifact_at(
    directory_descriptor: int,
    name: str,
    *,
    label: str,
    maximum_bytes: int,
    budget: BoundedReadBudget,
) -> bytes:
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0),
            dir_fd=directory_descriptor,
        )
    except OSError as error:
        raise EvidenceSupportError(f"{label} is unavailable: {error}") from error
    try:
        before = os.fstat(descriptor)
        require_secure_regular(before, label)
        require_path_identity(
            directory_descriptor,
            name,
            before,
            label=label,
        )
        if before.st_size > maximum_bytes:
            raise EvidenceSupportError(
                f"{label} exceeds its {maximum_bytes}-byte file read bound"
            )
        budget.ensure_capacity(before.st_size, label)
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
        after = os.fstat(descriptor)
        if (
            not same_identity(before, after)
            or after.st_size != before.st_size
            or after.st_mtime_ns != before.st_mtime_ns
            or after.st_ctime_ns != before.st_ctime_ns
            or total != before.st_size
        ):
            raise EvidenceSupportError(f"{label} changed during its bounded read")
        require_path_identity(
            directory_descriptor,
            name,
            after,
            label=label,
        )
        budget.consume(total, label)
        return b"".join(chunks)
    except OSError as error:
        raise EvidenceSupportError(f"{label} read failed: {error}") from error
    finally:
        os.close(descriptor)


class GateLock:
    def __init__(
        self,
        descriptor: int,
        directory_descriptor: int,
        name: str,
        identity: os.stat_result,
    ) -> None:
        self.descriptor = descriptor
        self.directory_descriptor = directory_descriptor
        self.name = name
        self.identity = identity

    def validate(self) -> None:
        require_path_identity(
            self.directory_descriptor,
            self.name,
            self.identity,
            label="gate serialization lock",
        )


def acquire_gate_lock(
    directory_descriptor: int,
    name: str,
    timeout_seconds: float,
) -> GateLock:
    if (
        not math.isfinite(timeout_seconds)
        or not 0 < timeout_seconds <= MAXIMUM_GATE_LOCK_WAIT_SECONDS
    ):
        raise SystemExit(
            "gate lock timeout must be greater than zero and no more than "
            f"{MAXIMUM_GATE_LOCK_WAIT_SECONDS:g} seconds"
        )
    existing = require_artifact_path(
        directory_descriptor,
        name,
        label="gate serialization lock",
    )
    flags = (
        os.O_RDWR
        | os.O_CREAT
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        descriptor = os.open(
            name,
            flags,
            0o600,
            dir_fd=directory_descriptor,
        )
    except OSError as error:
        raise EvidenceSupportError(f"cannot open gate serialization lock: {error}") from error
    try:
        metadata = os.fstat(descriptor)
        require_secure_regular(metadata, "gate serialization lock")
        if existing is not None and not same_identity(existing, metadata):
            raise EvidenceSupportError("gate serialization lock pathname identity changed")
        require_path_identity(
            directory_descriptor,
            name,
            metadata,
            label="gate serialization lock",
        )
        if existing is None:
            os.fsync(directory_descriptor)
        deadline = time.monotonic() + timeout_seconds
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                require_path_identity(
                    directory_descriptor,
                    name,
                    metadata,
                    label="gate serialization lock",
                )
                return GateLock(
                    descriptor,
                    directory_descriptor,
                    name,
                    metadata,
                )
            except BlockingIOError:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise EvidenceSupportError(
                        "timed out waiting for the "
                        f"{timeout_seconds:g}-second gate serialization bound"
                    )
                time.sleep(min(0.05, remaining))
    except Exception:
        os.close(descriptor)
        raise


def release_gate_lock(lock: GateLock) -> None:
    try:
        fcntl.flock(lock.descriptor, fcntl.LOCK_UN)
    except OSError:
        pass
    finally:
        try:
            os.close(lock.descriptor)
        except OSError:
            pass


class GateHandler:
    def __init__(
        self,
        result_directory: GateResultDirectory,
        directory_descriptor: int,
        directory_identity: os.stat_result,
        descriptor: int,
        identity: os.stat_result,
        raw: bytes,
        name: str,
        path: Path,
    ) -> None:
        self.result_directory = result_directory
        self.directory_descriptor = directory_descriptor
        self.directory_identity = directory_identity
        self.descriptor = descriptor
        self.identity = identity
        self.raw = raw
        self.name = name
        self.path = path

    def validate(self) -> None:
        self.result_directory.validate()
        require_directory_path_identity(
            self.result_directory.state_descriptor,
            "gate-handlers",
            self.directory_identity,
            label="gate-handlers directory",
        )
        require_path_identity(
            self.directory_descriptor,
            self.name,
            self.identity,
            label="gate handler",
        )


@contextmanager
def open_gate_handler(
    result_directory: GateResultDirectory,
    gate_identifier: str,
    path: Path,
):
    directory_descriptor: int | None = None
    descriptor: int | None = None
    flags = directory_open_flags()
    try:
        try:
            directory_descriptor = os.open(
                "gate-handlers",
                flags,
                dir_fd=result_directory.state_descriptor,
            )
        except FileNotFoundError:
            yield None
            return
        directory_identity = os.fstat(directory_descriptor)
        require_secure_directory(directory_identity, "gate-handlers directory")
        require_directory_path_identity(
            result_directory.state_descriptor,
            "gate-handlers",
            directory_identity,
            label="gate-handlers directory",
        )
        name = f"{gate_identifier}.sh"
        metadata = require_artifact_path(
            directory_descriptor,
            name,
            label="gate handler",
        )
        if metadata is None:
            yield None
            return
        descriptor = os.open(
            name,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0),
            dir_fd=directory_descriptor,
        )
        opened = os.fstat(descriptor)
        require_secure_regular(opened, "gate handler")
        if not same_identity(metadata, opened):
            raise EvidenceSupportError("gate handler pathname identity changed")
        executable_mode = opened.st_mode | 0o111
        if executable_mode != opened.st_mode:
            os.fchmod(descriptor, executable_mode)
        identity = os.fstat(descriptor)
        require_secure_regular(identity, "gate handler")
        if identity.st_size > MAXIMUM_GATE_HANDLER_BYTES:
            raise EvidenceSupportError(
                "gate handler exceeds its 1048576-byte read bound"
            )
        os.lseek(descriptor, 0, os.SEEK_SET)
        chunks: list[bytes] = []
        total = 0
        while True:
            block = os.read(
                descriptor,
                min(64 * 1024, MAXIMUM_GATE_HANDLER_BYTES - total + 1),
            )
            if not block:
                break
            total += len(block)
            if total > MAXIMUM_GATE_HANDLER_BYTES:
                raise EvidenceSupportError(
                    "gate handler exceeds its 1048576-byte read bound"
                )
            chunks.append(block)
        final_identity = os.fstat(descriptor)
        if (
            not same_identity(identity, final_identity)
            or final_identity.st_size != identity.st_size
            or final_identity.st_mtime_ns != identity.st_mtime_ns
            or final_identity.st_ctime_ns != identity.st_ctime_ns
            or total != identity.st_size
        ):
            raise EvidenceSupportError("gate handler changed during its bounded read")
        require_path_identity(
            directory_descriptor,
            name,
            final_identity,
            label="gate handler",
        )
        handler = GateHandler(
            result_directory,
            directory_descriptor,
            directory_identity,
            descriptor,
            final_identity,
            b"".join(chunks),
            name,
            path,
        )
        handler.validate()
        body_succeeded = False
        try:
            yield handler
            body_succeeded = True
        finally:
            if body_succeeded:
                handler.validate()
    except OSError as error:
        raise EvidenceSupportError(
            f"gate handler is unavailable or contains a symlink: {error}"
        ) from error
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if directory_descriptor is not None:
            os.close(directory_descriptor)


def handler_snapshot_command(raw: bytes, descriptor: int) -> list[str]:
    first_line = raw.splitlines()[0] if raw.splitlines() else b""
    if not first_line.startswith(b"#!"):
        raise EvidenceSupportError("gate handler has no executable interpreter")
    try:
        specification = first_line[2:].decode("utf-8", errors="strict").strip()
        interpreter = shlex.split(specification, posix=True)
    except (UnicodeError, ValueError) as error:
        raise EvidenceSupportError(f"gate handler interpreter is invalid: {error}") from error
    if (
        not interpreter
        or len(interpreter) > 2
        or not interpreter[0].startswith("/")
        or "\x00" in specification
    ):
        raise EvidenceSupportError("gate handler interpreter is invalid")
    if interpreter == ["/usr/bin/env", "python3"]:
        try:
            return [*interpreter, "-c", raw.decode("utf-8", errors="strict")]
        except UnicodeError as error:
            raise EvidenceSupportError(
                f"gate handler source is not UTF-8: {error}"
            ) from error
    return [*interpreter, f"/dev/fd/{descriptor}"]


@contextmanager
def open_unlinked_handler_snapshot(
    result_directory: GateResultDirectory,
    handler: GateHandler,
):
    directory_descriptor: int | None = None
    write_descriptor: int | None = None
    read_descriptor: int | None = None
    snapshot_name = f".{handler.name}.{uuid.uuid4().hex}.snapshot"
    try:
        directory_descriptor = os.open(
            "gate-handlers",
            directory_open_flags(),
            dir_fd=result_directory.state_descriptor,
        )
        directory_identity = os.fstat(directory_descriptor)
        require_secure_directory(directory_identity, "gate-handlers directory")
        if not same_identity(directory_identity, handler.directory_identity):
            raise EvidenceSupportError("gate-handlers directory pathname identity changed")
        require_directory_path_identity(
            result_directory.state_descriptor,
            "gate-handlers",
            handler.directory_identity,
            label="gate-handlers directory",
        )
        write_descriptor = os.open(
            snapshot_name,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            0o500,
            dir_fd=directory_descriptor,
        )
        write_all(write_descriptor, handler.raw)
        os.fchmod(write_descriptor, 0o500)
        os.fsync(write_descriptor)
        snapshot_identity = os.fstat(write_descriptor)
        require_secure_regular(snapshot_identity, "gate handler snapshot")
        os.close(write_descriptor)
        write_descriptor = None

        read_descriptor = os.open(
            snapshot_name,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0),
            dir_fd=directory_descriptor,
        )
        reopened_identity = os.fstat(read_descriptor)
        require_secure_regular(reopened_identity, "gate handler snapshot")
        if not same_identity(snapshot_identity, reopened_identity):
            raise EvidenceSupportError("gate handler snapshot pathname identity changed")
        require_path_identity(
            directory_descriptor,
            snapshot_name,
            reopened_identity,
            label="gate handler snapshot",
        )
        os.unlink(snapshot_name, dir_fd=directory_descriptor)
        os.fsync(directory_descriptor)
        execution_identity = os.fstat(read_descriptor)
        body_succeeded = False
        try:
            yield read_descriptor
            body_succeeded = True
        finally:
            if body_succeeded:
                final_identity = os.fstat(read_descriptor)
                if regular_snapshot(final_identity) != regular_snapshot(
                    execution_identity
                ):
                    raise EvidenceSupportError(
                        "gate handler snapshot changed during execution"
                    )
                chunks: list[bytes] = []
                offset = 0
                while offset < len(handler.raw):
                    block = os.pread(
                        read_descriptor,
                        min(64 * 1024, len(handler.raw) - offset),
                        offset,
                    )
                    if not block:
                        break
                    chunks.append(block)
                    offset += len(block)
                if offset != len(handler.raw) or b"".join(chunks) != handler.raw:
                    raise EvidenceSupportError(
                        "gate handler snapshot bytes changed during execution"
                    )
    except OSError as error:
        raise EvidenceSupportError(f"cannot prepare gate handler snapshot: {error}") from error
    finally:
        if write_descriptor is not None:
            os.close(write_descriptor)
        if read_descriptor is not None:
            os.close(read_descriptor)
        if directory_descriptor is not None:
            try:
                os.unlink(snapshot_name, dir_fd=directory_descriptor)
                os.fsync(directory_descriptor)
            except FileNotFoundError:
                pass
            os.close(directory_descriptor)


def bounded_state_control(
    repository: Path,
    command: list[str],
) -> tuple[bool, str]:
    try:
        return_code, stdout, stderr = run_bounded_readonly_command(
            repository,
            "gate state transition",
            command,
            timeout_seconds=MAXIMUM_STATE_CONTROL_SECONDS,
            maximum_output_bytes=MAXIMUM_STATE_CONTROL_OUTPUT_BYTES,
        )
    except BoundedCommandError as error:
        diagnostic = str(error)
        if error.stderr or error.stdout:
            diagnostic += ": " + (error.stderr + error.stdout)[
                :MAXIMUM_STATE_CONTROL_DIAGNOSTIC_BYTES
            ].decode("utf-8", errors="replace").strip()
        return False, diagnostic
    except EvidenceSupportError as error:
        return False, str(error)
    if return_code == 0:
        return True, ""
    output = (stderr + stdout)[:MAXIMUM_STATE_CONTROL_DIAGNOSTIC_BYTES].decode(
        "utf-8",
        errors="replace",
    ).strip()
    suffix = f": {output}" if output else ""
    return False, f"gate state transition exited {return_code}{suffix}"


def load_gate_plan(
    repository: Path,
    gate_identifier: str,
    json_budget: BoundedReadBudget,
) -> list[str]:
    try:
        gate_plan_raw = read_bounded_repository_bytes(
            repository,
            ".forge-codex/plans/gates.json",
            label="gate plan",
            maximum_bytes=MAXIMUM_QUALIFICATION_ARTIFACT_BYTES,
            budget=json_budget,
        )
        gate_plan = decode_strict_json_object(gate_plan_raw, label="gate plan")
    except EvidenceSupportError as error:
        raise SystemExit(f"cannot read gate plan: {error}") from error
    gate = next(
        (
            item
            for item in gate_plan.get("gates", [])
            if isinstance(item, dict) and item.get("id") == gate_identifier
        ),
        None,
    )
    if gate is None:
        raise SystemExit(f"Unknown gate: {gate_identifier}")
    planned_criteria = gate.get("criteria")
    if (
        not isinstance(planned_criteria, list)
        or not planned_criteria
        or any(not isinstance(item, str) or not item for item in planned_criteria)
        or len(set(planned_criteria)) != len(planned_criteria)
    ):
        raise SystemExit(f"Gate {gate_identifier} has an invalid criteria plan")
    return planned_criteria


def reconcile_state_control(
    repository: Path,
    package: Path,
    gate_identifier: str,
    expected_status: str,
    operation_id: str,
    initial_diagnostic: str,
) -> tuple[bool, str]:
    try:
        return_code, stdout, stderr = run_bounded_readonly_command(
            repository,
            "gate state transition reconciliation",
            [
                str(package / "scripts/statectl.py"),
                "--repo",
                str(repository),
                "show",
            ],
            timeout_seconds=10.0,
            maximum_output_bytes=4 * 1024 * 1024,
        )
        if return_code != 0:
            output = (stderr + stdout)[
                :MAXIMUM_STATE_CONTROL_DIAGNOSTIC_BYTES
            ].decode("utf-8", errors="replace").strip()
            suffix = f": {output}" if output else ""
            return (
                False,
                f"{initial_diagnostic}; reconciliation exited {return_code}{suffix}",
            )
        state = decode_strict_json_object(
            stdout,
            label="gate state transition reconciliation",
        )
        gates = state.get("gates")
        item = gates.get(gate_identifier) if isinstance(gates, dict) else None
        if (
            isinstance(item, dict)
            and item.get("status") == expected_status
            and item.get("operation_id") == operation_id
        ):
            return True, ""
        return False, f"{initial_diagnostic}; exact operation was not committed"
    except (BoundedCommandError, EvidenceSupportError) as error:
        return False, f"{initial_diagnostic}; reconciliation failed: {error}"


def evaluate_locked_gate(
    repository: Path,
    package: Path,
    gate_identifier: str,
    planned_criteria: list[str],
    timeout_seconds: int,
    json_budget: BoundedReadBudget,
    opened_result_directory: GateResultDirectory,
    gate_lock: GateLock,
) -> tuple[dict[str, object], int]:
    result_directory_descriptor = opened_result_directory.descriptor
    operation_id = str(uuid.uuid4())
    handler = package / "state/gate-handlers" / f"{gate_identifier}.sh"
    result_directory = package / "state/gate-results"
    criteria_name = f"{gate_identifier}.criteria.json"
    result_name = f"{gate_identifier}.json"
    stdout_name = f"{gate_identifier}.stdout.txt"
    stderr_name = f"{gate_identifier}.stderr.txt"
    criteria_path = result_directory / criteria_name
    result_path = result_directory / result_name
    stdout_path = result_directory / stdout_name
    stderr_path = result_directory / stderr_name

    for name, label in (
        (criteria_name, f"{gate_identifier} criteria sidecar"),
        (result_name, f"{gate_identifier} gate result"),
        (stdout_name, f"{gate_identifier} stdout artifact"),
        (stderr_name, f"{gate_identifier} stderr artifact"),
    ):
        durable_unlink_at(
            result_directory_descriptor,
            name,
            label=label,
        )
    source_identity = capture_source_identity(repository)
    state_sequence_before = current_state_sequence(repository)
    started = now()

    with open_gate_handler(
        opened_result_directory,
        gate_identifier,
        handler,
    ) as initial_handler:
        pass
    if initial_handler is None:
        status = "failed"
        commands = [
            {
                "command": str(handler),
                "exit_code": 127,
                "stdout_sha256": None,
                "stderr_sha256": None,
                "timed_out": False,
            }
        ]
        artifacts: list[dict[str, object]] = []
        evaluator = {
            "name": "handler-presence",
            "version": "1",
            "criteria_results": [
                {
                    "criterion": "gate handler exists",
                    "passed": False,
                    "evidence": str(handler),
                }
            ],
        }
        notes = (
            "No gate handler exists. A deterministic handler must evaluate "
            "every criterion."
        )
    else:
        timed_out = False
        try:
            with open_unlinked_handler_snapshot(
                opened_result_directory,
                initial_handler,
            ) as snapshot_descriptor:
                handler_environment = dict(os.environ)
                handler_environment["FORGE_GATE_REPOSITORY_ROOT"] = str(repository)
                code, stdout_bytes, stderr_bytes = run_bounded_readonly_command(
                    repository,
                    f"{gate_identifier} gate handler",
                    handler_snapshot_command(
                        initial_handler.raw,
                        snapshot_descriptor,
                    ),
                    timeout_seconds=timeout_seconds,
                    maximum_output_bytes=MAXIMUM_GATE_OUTPUT_BYTES,
                    environment=handler_environment,
                    pass_fds=(snapshot_descriptor,),
                )
        except BoundedCommandError as error:
            timed_out = error.timed_out
            code = 124 if timed_out else 125
            stdout_bytes = error.stdout
            stderr_bytes = error.stderr
            diagnostic = (str(error) + "\n").encode("utf-8", errors="replace")
            remaining_output = max(
                0,
                MAXIMUM_GATE_OUTPUT_BYTES - len(stdout_bytes) - len(stderr_bytes),
            )
            stderr_bytes += diagnostic[:remaining_output]
        except EvidenceSupportError as error:
            code = 125
            stdout_bytes = b""
            stderr_bytes = (str(error) + "\n").encode("utf-8", errors="replace")
        with open_gate_handler(
            opened_result_directory,
            gate_identifier,
            handler,
        ) as current_handler:
            if current_handler is None or not (
                same_identity(
                    current_handler.directory_identity,
                    initial_handler.directory_identity,
                )
                and regular_snapshot(current_handler.identity)
                == regular_snapshot(initial_handler.identity)
                and current_handler.raw == initial_handler.raw
            ):
                raise EvidenceSupportError("gate handler pathname identity changed")
        atomic_write_bytes_at(
            result_directory_descriptor,
            stdout_name,
            stdout_bytes,
            label=f"{gate_identifier} stdout artifact",
        )
        atomic_write_bytes_at(
            result_directory_descriptor,
            stderr_name,
            stderr_bytes,
            label=f"{gate_identifier} stderr artifact",
        )
        stdout_hash = hashlib.sha256(stdout_bytes).hexdigest()
        stderr_hash = hashlib.sha256(stderr_bytes).hexdigest()
        commands = [
            {
                "command": str(handler),
                "exit_code": code,
                "stdout_sha256": stdout_hash,
                "stderr_sha256": stderr_hash,
                "timed_out": timed_out,
            }
        ]
        artifacts = [
            {"path": str(stdout_path), "sha256": stdout_hash, "kind": "stdout"},
            {"path": str(stderr_path), "sha256": stderr_hash, "kind": "stderr"},
        ]
        if stat_path_at(result_directory_descriptor, criteria_name) is not None:
            criteria_captured = False
            try:
                criteria_raw = read_bounded_artifact_at(
                    result_directory_descriptor,
                    criteria_name,
                    label=f"{gate_identifier} criteria sidecar",
                    maximum_bytes=MAXIMUM_QUALIFICATION_ARTIFACT_BYTES,
                    budget=json_budget,
                )
                criteria_captured = True
                criteria_document = decode_strict_json_object(
                    criteria_raw,
                    label=f"{gate_identifier} criteria sidecar",
                )
                criteria = criteria_document["criteria_results"]
                if not isinstance(criteria, list):
                    raise ValueError("criteria_results is not an array")
                if len(criteria) != len(planned_criteria):
                    raise ValueError("criteria_results count does not match gate plan")
                for index, (item, expected) in enumerate(
                    zip(criteria, planned_criteria)
                ):
                    if not isinstance(item, dict):
                        raise ValueError(
                            f"criteria_results[{index}] is not an object"
                        )
                    if item.get("criterion") != expected:
                        raise ValueError(
                            f"criteria_results[{index}] does not match gate plan"
                        )
                    if not isinstance(item.get("passed"), bool):
                        raise ValueError(
                            f"criteria_results[{index}].passed is not boolean"
                        )
            except (EvidenceSupportError, KeyError, ValueError) as error:
                criteria = [
                    {
                        "criterion": "criteria sidecar parses",
                        "passed": False,
                        "evidence": repr(error),
                    }
                ]
            if criteria_captured:
                atomic_write_bytes_at(
                    result_directory_descriptor,
                    criteria_name,
                    criteria_raw,
                    label=f"{gate_identifier} criteria sidecar",
                )
                artifacts.append(
                    {
                        "path": str(criteria_path),
                        "sha256": hashlib.sha256(criteria_raw).hexdigest(),
                        "kind": "criteria",
                    }
                )
        else:
            criteria = [
                {
                    "criterion": criterion,
                    "passed": False,
                    "evidence": "criteria sidecar missing after handler execution",
                }
                for criterion in planned_criteria
            ]
        status = (
            "passed"
            if code == 0
            and bool(criteria)
            and all(
                isinstance(item, dict) and item.get("passed") is True
                for item in criteria
            )
            else "failed"
        )
        evaluator = {
            "name": "forge-gate-handler",
            "version": "1",
            "criteria_results": criteria,
        }
        notes = ""

    final_source_identity = capture_source_identity(repository)
    if final_source_identity != source_identity:
        raise EvidenceSupportError(
            "gate source identity changed during evaluation"
        )

    result: dict[str, object] = {
        "schema_version": 1,
        "gate_id": gate_identifier,
        "operation_id": operation_id,
        **source_identity,
        "state_sequence_before": state_sequence_before,
        "status": status,
        "finalized": True,
        "started_at": started,
        "ended_at": now(),
        "commands": commands,
        "environment": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "repository": str(repository),
        },
        "artifacts": artifacts,
        "evaluator": evaluator,
        "notes": notes,
    }

    # The evaluated result is durable before statectl receives its matching
    # operation identifier. Therefore a passed state item always names a result
    # that was already present on disk.
    atomic_write_json_at(
        result_directory_descriptor,
        result_name,
        result,
        label=f"{gate_identifier} gate result",
    )
    opened_result_directory.validate()
    gate_lock.validate()
    evidence_ids = [str(artifact["sha256"]) for artifact in artifacts]
    state_command = [
        str(package / "scripts/statectl.py"),
        "--repo",
        str(repository),
        "gate",
        gate_identifier,
        status,
        *sum(((["--evidence", evidence_id]) for evidence_id in evidence_ids), []),
        "--evaluator",
        str(result_path),
        "--operation-id",
        operation_id,
    ]
    state_control_succeeded, state_control_diagnostic = bounded_state_control(
        repository,
        state_command,
    )
    if not state_control_succeeded:
        state_control_succeeded, state_control_diagnostic = reconcile_state_control(
            repository,
            package,
            gate_identifier,
            status,
            operation_id,
            state_control_diagnostic,
        )
    if not state_control_succeeded:
        result["status"] = "failed"
        result["finalized"] = False
        prefix = f"{notes} " if notes else ""
        result["notes"] = (
            prefix + f"State control failed closed: {state_control_diagnostic}"
        )
        result["ended_at"] = now()
        atomic_write_json_at(
            result_directory_descriptor,
            result_name,
            result,
            label=f"{gate_identifier} gate result",
        )

    print(json.dumps(result, indent=2))
    return result, 0 if state_control_succeeded and status == "passed" else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("gate")
    parser.add_argument("--repo")
    parser.add_argument("--timeout", type=int, default=7200)
    parser.add_argument(
        "--lock-timeout",
        type=float,
        default=MAXIMUM_GATE_LOCK_WAIT_SECONDS,
        help=argparse.SUPPRESS,
    )
    arguments = parser.parse_args()
    gate_identifier = validate_gate_identifier(arguments.gate)
    repository = locate_repo(arguments.repo)
    package = repository / ".forge-codex"
    json_budget = BoundedReadBudget(
        MAXIMUM_GATE_JSON_AGGREGATE_BYTES,
        "gate JSON/control input",
    )
    planned_criteria = load_gate_plan(
        repository,
        gate_identifier,
        json_budget,
    )
    gate_lock: GateLock | None = None
    with open_gate_result_directory(repository) as opened_result_directory:
        gate_lock = acquire_gate_lock(
            opened_result_directory.descriptor,
            f".{gate_identifier}.lock",
            arguments.lock_timeout,
        )
        try:
            _, exit_code = evaluate_locked_gate(
                repository,
                package,
                gate_identifier,
                planned_criteria,
                arguments.timeout,
                json_budget,
                opened_result_directory,
                gate_lock,
            )
            return exit_code
        finally:
            release_gate_lock(gate_lock)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except EvidenceSupportError as error:
        raise SystemExit(str(error)) from error
