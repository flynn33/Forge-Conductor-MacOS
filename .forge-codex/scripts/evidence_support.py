#!/usr/bin/env python3
"""Shared deterministic and bounded helpers for command-backed evidence."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import selectors
import signal
import stat
import subprocess
import tempfile
import time
from dataclasses import dataclass
from typing import Any, Iterable, Mapping


MANIFEST_SCHEMA_VERSION = 1
EVIDENCE_CONTEXT_SCHEMA_VERSION = 1
QUALIFICATION_ARTIFACT_BINDING_SCHEMA_VERSION = 1
QUALIFICATION_ARTIFACT_NAME = "p10-privileged-filesystem"
MAXIMUM_QUALIFICATION_ARTIFACT_BYTES = 1024 * 1024
MAXIMUM_QUALIFICATION_SCHEMA_BYTES = 1024 * 1024
MAXIMUM_MANIFEST_FILE_BYTES = 64 * 1024 * 1024
MAXIMUM_MANIFEST_TOTAL_BYTES = 512 * 1024 * 1024
MAXIMUM_MANIFEST_FILES = 32 * 1024
MAXIMUM_MANIFEST_ENTRIES = 64 * 1024
MAXIMUM_MANIFEST_DEPTH = 128
MAXIMUM_REPOSITORY_SCAN_ENTRIES = 64 * 1024
MAXIMUM_REPOSITORY_SCAN_DEPTH = 128
MAXIMUM_JSON_NUMBER_CHARACTERS = 128
MAXIMUM_GIT_IDENTITY_OUTPUT_BYTES = 4096
MAXIMUM_GIT_IDENTITY_SECONDS = 10.0
COMMAND_TERMINATION_GRACE_SECONDS = 1.0
COMMAND_TERMINATION_WAIT_SECONDS = 2.0
MANIFEST_TARGETS = (
    "Package.swift",
    "ForgeConductor.xcodeproj/project.pbxproj",
    "ForgeConductor.xcodeproj/xcshareddata/xcschemes/ForgeFilesystemQualification.xcscheme",
    "script",
    "Sources",
    "Tests",
    ".forge-codex/scripts",
    ".forge-codex/scripts/record_command.py",
    ".forge-codex/scripts/evidence_support.py",
    ".forge-codex/scripts/run_privileged_filesystem_h0.py",
    ".forge-codex/scripts/test_run_privileged_filesystem_h0.py",
    ".forge-codex/scripts/run_privileged_filesystem_admission_observation.py",
    ".forge-codex/scripts/test_run_privileged_filesystem_admission_observation.py",
    ".forge-codex/scripts/check_p10_completion.py",
    ".forge-codex/scripts/check_p10_cli_compatibility.py",
    ".forge-codex/scripts/check_p10_manager_http_compatibility.py",
    ".forge-codex/scripts/check_p10_protocol_compatibility.py",
    ".forge-codex/scripts/run_gate.py",
    ".forge-codex/scripts/run_gates.sh",
    ".forge-codex/scripts/scan_attribution.py",
    ".forge-codex/scripts/scan_secrets.py",
    ".forge-codex/scripts/statectl.py",
    ".forge-codex/scripts/validate_package.py",
    ".forge-codex/scripts/verify_completion.py",
    ".forge-codex/scripts/test_acceptance_compatibility.py",
    ".forge-codex/scripts/test_evidence_controls.py",
    ".forge-codex/scripts/test_gate_runner_hardening.py",
    ".forge-codex/scripts/test_release_scanners_hardening.py",
    ".forge-codex/scripts/test_statectl_transactions.py",
    ".forge-codex/scripts/test_verify_completion_hardening.py",
    ".forge-codex/scripts/validate_acceptance.py",
    ".forge-codex/plans/gates.json",
    ".forge-codex/plans/phases.json",
    ".forge-codex/state/acceptance",
    ".forge-codex/state/feature-baseline.json",
    ".forge-codex/state/findings-resolution.json",
    ".forge-codex/state/gate-handlers",
    ".forge-codex/state/host-capability-report.json",
    ".forge-codex/state/gate-handlers/G10.sh",
    ".forge-codex/state/gate-handlers/G12.sh",
    ".forge-codex/templates/gate-handlers/G10.sh",
    ".forge-codex/templates/gate-handlers/G12.sh",
    ".forge-codex/templates/gate-handlers",
    ".forge-codex/schemas/p10-privileged-filesystem-artifact-binding.schema.json",
    ".forge-codex/schemas/p10-privileged-filesystem-h0-readiness.schema.json",
    ".forge-codex/schemas/p10-privileged-filesystem-admission-observation.schema.json",
    ".forge-codex/schemas/p10-privileged-filesystem-qualification-report.schema.json",
    ".forge-codex/schemas/p10-feature-production-qualification.schema.json",
    ".forge-codex/specifications/p10-feature-registry.v1.json",
    ".forge-codex/specifications/p10-production-probes.v1.json",
    ".forge-codex/scripts/qualify_p10_features.py",
    ".forge-codex/templates/p10-privileged-filesystem-qualification-report.json",
    ".forge-codex/docs/PRIVILEGED_FILESYSTEM_QUALIFICATION.md",
    ".forge-codex/architecture/SECURITY_AND_PRIVACY.md",
    ".forge-codex/specifications/COMPLETION_GATES.md",
    ".forge-codex/state/baseline",
)
IGNORED_MANIFEST_NAMES = {".DS_Store", "__pycache__"}
XCTEST_SUMMARY = re.compile(
    r"Executed (?P<executed>\d+) tests?, with "
    r"(?:(?P<skipped>\d+) tests? skipped and )?"
    r"(?P<failures>\d+) failures?"
)
GIT_COMMIT_PATTERN = re.compile(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})")
QUALIFICATION_ARTIFACT_ROLES = frozenset({
    "qualification_context",
    "case_result",
    "barrier",
    "process_identity",
    "signing_identity",
    "fixture_before",
    "fixture_after",
    "mount",
    "crash",
    "formal_argument",
})
QUALIFICATION_ARTIFACT_SUBJECT_ROLES = frozenset({
    "barrier",
    "process_identity",
    "signing_identity",
    "fixture_before",
    "fixture_after",
})
QUALIFICATION_ARTIFACT_PLACEHOLDER_VALUES = frozenset({
    "fixture",
    "n/a",
    "not run",
    "not-run",
    "not_run",
    "placeholder",
    "tbd",
    "todo",
    "unknown",
    "unset",
})


class EvidenceSupportError(RuntimeError):
    """Raised when evidence cannot be produced within its declared bounds."""


class BoundedCommandError(EvidenceSupportError):
    """Bounded command failure that retains only the bytes captured within policy."""

    def __init__(
        self,
        message: str,
        *,
        stdout: bytes,
        stderr: bytes,
        timed_out: bool,
        output_limit_exceeded: bool,
    ) -> None:
        super().__init__(message)
        self.stdout = stdout
        self.stderr = stderr
        self.timed_out = timed_out
        self.output_limit_exceeded = output_limit_exceeded


class BoundedReadBudget:
    """Track a deterministic aggregate byte budget across trusted read helpers."""

    def __init__(self, maximum_bytes: int, label: str) -> None:
        if maximum_bytes <= 0 or not label.strip():
            raise EvidenceSupportError("bounded read budget is invalid")
        self.maximum_bytes = maximum_bytes
        self.label = label
        self.consumed_bytes = 0

    @property
    def remaining_bytes(self) -> int:
        return self.maximum_bytes - self.consumed_bytes

    def ensure_capacity(self, byte_count: int, item_label: str) -> None:
        if byte_count < 0 or byte_count > self.remaining_bytes:
            raise EvidenceSupportError(
                f"{item_label} exceeds the {self.label} "
                f"{self.maximum_bytes}-byte aggregate read bound"
            )

    def consume(self, byte_count: int, item_label: str) -> None:
        self.ensure_capacity(byte_count, item_label)
        self.consumed_bytes += byte_count


@dataclass(frozen=True)
class RepositoryTreeEntry:
    """One stable, non-symlink repository tree entry."""

    relative_path: pathlib.PurePosixPath
    mode: int
    size: int

    @property
    def is_file(self) -> bool:
        return stat.S_ISREG(self.mode)

    @property
    def is_directory(self) -> bool:
        return stat.S_ISDIR(self.mode)


def _stable_tree_metadata(metadata: os.stat_result) -> tuple[int, ...]:
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


def bounded_repository_tree(
    repository_root: pathlib.Path,
    *,
    skip_names: frozenset[str] = frozenset(),
    maximum_entries: int = MAXIMUM_REPOSITORY_SCAN_ENTRIES,
    reject_symlinks: bool = True,
) -> list[RepositoryTreeEntry]:
    """Enumerate a stable repository tree without following path symlinks."""

    if maximum_entries <= 0:
        raise EvidenceSupportError("repository traversal bound is invalid")
    if any(
        not isinstance(name, str)
        or not name
        or name in {".", ".."}
        or "/" in name
        or "\0" in name
        for name in skip_names
    ):
        raise EvidenceSupportError("repository traversal skip set is invalid")
    try:
        canonical_root = repository_root.resolve(strict=True)
    except OSError as error:
        raise EvidenceSupportError(
            f"repository traversal root is unavailable: {error}"
        ) from error
    directory_flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_DIRECTORY", 0)
    )
    entries: list[RepositoryTreeEntry] = []
    observed_entries = 0

    def visit(
        directory_descriptor: int,
        relative_directory: pathlib.PurePosixPath,
        depth: int,
    ) -> None:
        nonlocal observed_entries
        if depth > MAXIMUM_REPOSITORY_SCAN_DEPTH:
            raise EvidenceSupportError(
                "repository traversal exceeds its directory depth bound"
            )
        directory_before = os.fstat(directory_descriptor)
        if not stat.S_ISDIR(directory_before.st_mode):
            raise EvidenceSupportError("repository traversal opened a non-directory")
        try:
            names: list[str] = []
            with os.scandir(directory_descriptor) as iterator:
                for directory_entry in iterator:
                    observed_entries += 1
                    if observed_entries > maximum_entries:
                        raise EvidenceSupportError(
                            f"repository traversal exceeds {maximum_entries} entries"
                        )
                    names.append(directory_entry.name)
        except OSError as error:
            raise EvidenceSupportError(
                f"repository directory cannot be enumerated: {error}"
            ) from error
        for name in names:
            if name in skip_names:
                continue
            relative = (
                pathlib.PurePosixPath(name)
                if not relative_directory.parts
                else relative_directory / name
            )
            if len(relative.as_posix().encode("utf-8", errors="strict")) > 4096:
                raise EvidenceSupportError(
                    "repository traversal path exceeds its byte bound"
                )
            try:
                metadata = os.stat(
                    name,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
            except OSError as error:
                raise EvidenceSupportError(
                    f"repository entry cannot be inspected: {relative}: {error}"
                ) from error
            if stat.S_ISLNK(metadata.st_mode):
                if reject_symlinks:
                    raise EvidenceSupportError(
                        f"repository traversal encountered a symbolic link: {relative}"
                    )
                entries.append(RepositoryTreeEntry(relative, metadata.st_mode, metadata.st_size))
                continue
            if not (stat.S_ISREG(metadata.st_mode) or stat.S_ISDIR(metadata.st_mode)):
                raise EvidenceSupportError(
                    f"repository traversal encountered a special file: {relative}"
                )
            if metadata.st_uid != os.geteuid():
                raise EvidenceSupportError(
                    f"repository entry is not owned by the current user: {relative}"
                )
            if stat.S_ISREG(metadata.st_mode) and metadata.st_mode & 0o022:
                raise EvidenceSupportError(
                    f"repository entry is group- or world-writable: {relative}"
                )
            if stat.S_ISREG(metadata.st_mode) and metadata.st_nlink != 1:
                raise EvidenceSupportError(
                    f"repository file has multiple hard links: {relative}"
                )
            entries.append(RepositoryTreeEntry(relative, metadata.st_mode, metadata.st_size))
            if not stat.S_ISDIR(metadata.st_mode):
                continue
            child_descriptor: int | None = None
            try:
                child_descriptor = os.open(
                    name,
                    directory_flags,
                    dir_fd=directory_descriptor,
                )
                opened = os.fstat(child_descriptor)
                if _stable_tree_metadata(opened) != _stable_tree_metadata(metadata):
                    raise EvidenceSupportError(
                        f"repository directory changed before traversal: {relative}"
                    )
                visit(child_descriptor, relative, depth + 1)
                after = os.fstat(child_descriptor)
                current = os.stat(
                    name,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
                if (
                    _stable_tree_metadata(after) != _stable_tree_metadata(metadata)
                    or _stable_tree_metadata(current) != _stable_tree_metadata(metadata)
                ):
                    raise EvidenceSupportError(
                        f"repository directory changed during traversal: {relative}"
                    )
            except OSError as error:
                raise EvidenceSupportError(
                    f"repository directory cannot be opened safely: {relative}: {error}"
                ) from error
            finally:
                if child_descriptor is not None:
                    os.close(child_descriptor)
        directory_after = os.fstat(directory_descriptor)
        if _stable_tree_metadata(directory_after) != _stable_tree_metadata(directory_before):
            label = relative_directory.as_posix() or "."
            raise EvidenceSupportError(
                f"repository directory changed during traversal: {label}"
            )

    root_descriptor: int | None = None
    try:
        root_descriptor = os.open(canonical_root, directory_flags)
        root_identity = os.fstat(root_descriptor)
        visit(root_descriptor, pathlib.PurePosixPath(), 0)
        current_root = os.stat(canonical_root, follow_symlinks=False)
        if _stable_tree_metadata(current_root) != _stable_tree_metadata(root_identity):
            raise EvidenceSupportError(
                "repository root changed during traversal"
            )
    except OSError as error:
        raise EvidenceSupportError(
            f"repository traversal failed closed: {error}"
        ) from error
    finally:
        if root_descriptor is not None:
            os.close(root_descriptor)
    return sorted(entries, key=lambda entry: entry.relative_path.as_posix())


def run_bounded_readonly_command(
    repository: pathlib.Path,
    label: str,
    command: list[str],
    *,
    timeout_seconds: float,
    maximum_output_bytes: int,
    environment: Mapping[str, str] | None = None,
    pass_fds: tuple[int, ...] = (),
) -> tuple[int, bytes, bytes]:
    """Run one fixed read-only command with a real aggregate output bound."""

    if timeout_seconds <= 0 or maximum_output_bytes <= 0:
        raise EvidenceSupportError(f"{label} has invalid execution bounds")
    try:
        process = subprocess.Popen(
            command,
            cwd=repository,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
            env=environment,
            pass_fds=pass_fds,
        )
    except OSError as error:
        raise EvidenceSupportError(f"{label} is unavailable: {error}") from error
    assert process.stdout is not None
    assert process.stderr is not None
    stdout_descriptor = process.stdout.fileno()
    stderr_descriptor = process.stderr.fileno()
    streams = {
        stdout_descriptor: (process.stdout, []),
        stderr_descriptor: (process.stderr, []),
    }
    selector = selectors.DefaultSelector()
    total = 0
    deadline = time.monotonic() + timeout_seconds
    exceeded = False
    timed_out = False
    try:
        for descriptor, (stream, _) in streams.items():
            os.set_blocking(descriptor, False)
            selector.register(stream, selectors.EVENT_READ, descriptor)
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                break
            events = selector.select(min(remaining, 0.25))
            for key, _ in events:
                descriptor = key.data
                try:
                    block = os.read(
                        descriptor,
                        min(64 * 1024, maximum_output_bytes - total + 1),
                    )
                except BlockingIOError:
                    continue
                if not block:
                    selector.unregister(key.fileobj)
                    continue
                allowed = max(0, maximum_output_bytes - total)
                if allowed:
                    streams[descriptor][1].append(block[:allowed])
                total += len(block)
                if total > maximum_output_bytes:
                    exceeded = True
                    break
            if exceeded:
                break
        if timed_out or exceeded:
            terminate_process_group(process)
        remaining = max(0.0, deadline - time.monotonic())
        try:
            return_code = process.wait(timeout=max(0.1, remaining))
        except subprocess.TimeoutExpired:
            terminate_process_group(process)
            timed_out = True
            return_code = process.returncode
    finally:
        selector.close()
        process.stdout.close()
        process.stderr.close()
    stdout = b"".join(streams[stdout_descriptor][1])
    stderr = b"".join(streams[stderr_descriptor][1])
    if timed_out:
        raise BoundedCommandError(
            f"{label} exceeded its time bound",
            stdout=stdout,
            stderr=stderr,
            timed_out=True,
            output_limit_exceeded=exceeded,
        )
    if exceeded:
        raise BoundedCommandError(
            f"{label} exceeds its read bound",
            stdout=stdout,
            stderr=stderr,
            timed_out=False,
            output_limit_exceeded=True,
        )
    return return_code, stdout, stderr


def terminate_process_group(process: subprocess.Popen[Any]) -> None:
    """Terminate a command session and reap its direct child within fixed bounds."""

    try:
        os.killpg(process.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        pass

    grace_deadline = time.monotonic() + COMMAND_TERMINATION_GRACE_SECONDS
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
        process.wait(timeout=COMMAND_TERMINATION_WAIT_SECONDS)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=COMMAND_TERMINATION_WAIT_SECONDS)


def current_git_head(repository: pathlib.Path) -> str | None:
    """Return the exact bounded Git HEAD, or None when no identity exists."""

    try:
        return_code, stdout, stderr = run_bounded_readonly_command(
            repository,
            "source Git identity",
            ["/usr/bin/git", "rev-parse", "--verify", "HEAD"],
            timeout_seconds=MAXIMUM_GIT_IDENTITY_SECONDS,
            maximum_output_bytes=MAXIMUM_GIT_IDENTITY_OUTPUT_BYTES,
        )
    except (BoundedCommandError, EvidenceSupportError):
        return None
    if return_code != 0 or stderr:
        return None
    try:
        value = stdout.decode("ascii", errors="strict").strip()
    except UnicodeError:
        return None
    if GIT_COMMIT_PATTERN.fullmatch(value) is None:
        return None
    return value.lower()


def canonical_json_sha256(value: Any) -> str:
    """Return the SHA-256 of one stable JSON value."""

    try:
        encoded = json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise EvidenceSupportError(f"value is not canonical JSON: {error}") from error
    return hashlib.sha256(encoded).hexdigest()


def _nonplaceholder_binding_text(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise EvidenceSupportError(f"qualification artifact {label} is empty")
    normalized = " ".join(value.strip().lower().replace("_", " ").split())
    if (
        normalized in QUALIFICATION_ARTIFACT_PLACEHOLDER_VALUES
        or "placeholder" in normalized
        or "not executed" in normalized
    ):
        raise EvidenceSupportError(f"qualification artifact {label} is a placeholder")
    return value


def _open_repository_relative_file(
    repository_root: pathlib.Path,
    relative_path: pathlib.PurePosixPath,
) -> int:
    """Open one repository-relative file without following any path symlink."""

    parts = relative_path.parts
    if (
        not parts
        or relative_path.is_absolute()
        or any(part in {"", ".", ".."} for part in parts)
    ):
        raise EvidenceSupportError(
            "qualification artifact path is not a strict repository-relative path"
        )
    directory_flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_DIRECTORY", 0)
    )
    file_flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    directory_descriptor: int | None = None
    try:
        directory_descriptor = os.open(repository_root, directory_flags)
        for component in parts[:-1]:
            next_descriptor = os.open(
                component,
                directory_flags,
                dir_fd=directory_descriptor,
            )
            os.close(directory_descriptor)
            directory_descriptor = next_descriptor
        return os.open(parts[-1], file_flags, dir_fd=directory_descriptor)
    except OSError as error:
        raise EvidenceSupportError(
            "qualification artifact path is unavailable or contains a symlink: "
            f"{error}"
        ) from error
    finally:
        if directory_descriptor is not None:
            os.close(directory_descriptor)


def _strict_repository_relative_path(
    relative_path: str | pathlib.PurePosixPath,
    *,
    label: str,
) -> pathlib.PurePosixPath:
    raw_relative = str(relative_path)
    try:
        encoded_relative = raw_relative.encode("utf-8", errors="strict")
    except UnicodeEncodeError as error:
        raise EvidenceSupportError(
            f"{label} path is not strict repository-relative"
        ) from error
    pure_relative = pathlib.PurePosixPath(raw_relative)
    if (
        not raw_relative
        or b"\0" in encoded_relative
        or len(encoded_relative) > 4096
        or "\\" in raw_relative
        or pure_relative.is_absolute()
        or pure_relative.as_posix() != raw_relative
        or any(part in {"", ".", ".."} for part in pure_relative.parts)
    ):
        raise EvidenceSupportError(
            f"{label} path is not strict repository-relative"
        )
    return pure_relative


def read_bounded_repository_bytes(
    repository_root: pathlib.Path,
    relative_path: str | pathlib.PurePosixPath,
    *,
    label: str,
    maximum_bytes: int,
    budget: BoundedReadBudget | None = None,
    require_owner_controlled: bool = False,
) -> bytes:
    """Read one stable regular repository file without following path symlinks."""

    if maximum_bytes <= 0:
        raise EvidenceSupportError(f"{label} has an invalid file read bound")
    if not repository_root.is_absolute():
        raise EvidenceSupportError(f"{label} repository root is not absolute")
    pure_relative = _strict_repository_relative_path(relative_path, label=label)

    descriptor = _open_repository_relative_file(repository_root, pure_relative)
    verification_descriptor: int | None = None
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise EvidenceSupportError(f"{label} is not a regular file")
        if require_owner_controlled and (
            before.st_uid != os.geteuid()
            or before.st_nlink != 1
            or stat.S_IMODE(before.st_mode) & 0o022
        ):
            raise EvidenceSupportError(
                f"{label} is not an owner-controlled single-link file"
            )
        if before.st_size > maximum_bytes:
            raise EvidenceSupportError(
                f"{label} exceeds its {maximum_bytes}-byte file read bound"
            )
        if budget is not None:
            budget.ensure_capacity(before.st_size, label)

        chunks: list[bytes] = []
        total = 0
        while True:
            next_read_bytes = maximum_bytes + 1 - total
            if budget is not None:
                next_read_bytes = min(
                    next_read_bytes,
                    budget.remaining_bytes + 1,
                )
            block = os.read(
                descriptor,
                min(64 * 1024, next_read_bytes),
            )
            if not block:
                break
            chunks.append(block)
            total += len(block)
            if total > maximum_bytes:
                raise EvidenceSupportError(
                    f"{label} exceeds its {maximum_bytes}-byte file read bound"
                )
            if budget is not None:
                budget.consume(len(block), label)

        after = os.fstat(descriptor)
        stable_before = (
            before.st_dev,
            before.st_ino,
            before.st_mode,
            before.st_uid,
            before.st_nlink,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        )
        stable_after = (
            after.st_dev,
            after.st_ino,
            after.st_mode,
            after.st_uid,
            after.st_nlink,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        )
        if stable_before != stable_after or total != before.st_size:
            raise EvidenceSupportError(f"{label} changed during its bounded read")

        verification_descriptor = _open_repository_relative_file(
            repository_root,
            pure_relative,
        )
        current = os.fstat(verification_descriptor)
        stable_current = (
            current.st_dev,
            current.st_ino,
            current.st_mode,
            current.st_uid,
            current.st_nlink,
            current.st_size,
            current.st_mtime_ns,
            current.st_ctime_ns,
        )
        if stable_current != stable_after:
            raise EvidenceSupportError(
                f"{label} pathname no longer names the opened file"
            )
    except OSError as error:
        raise EvidenceSupportError(f"{label} read failed: {error}") from error
    finally:
        try:
            if verification_descriptor is not None:
                os.close(verification_descriptor)
        finally:
            os.close(descriptor)

    return b"".join(chunks)


def decode_strict_json_object(raw: bytes, *, label: str) -> dict[str, Any]:
    """Decode one finite, bounded-lexeme UTF-8 JSON object without duplicate keys."""

    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate key: {key}")
            result[key] = value
        return result

    def reject_nonfinite_constant(value: str) -> Any:
        raise ValueError(f"non-finite numeric constant: {value}")

    def bounded_integer(value: str) -> int:
        if len(value) > MAXIMUM_JSON_NUMBER_CHARACTERS:
            raise ValueError("integer token exceeds its lexical bound")
        return int(value)

    def bounded_float(value: str) -> float:
        if len(value) > MAXIMUM_JSON_NUMBER_CHARACTERS:
            raise ValueError("floating-point token exceeds its lexical bound")
        parsed = float(value)
        if parsed == float("inf") or parsed == float("-inf") or parsed != parsed:
            raise ValueError("floating-point token is not finite")
        return parsed

    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_nonfinite_constant,
            parse_int=bounded_integer,
            parse_float=bounded_float,
        )
    except (UnicodeError, json.JSONDecodeError, ValueError) as error:
        raise EvidenceSupportError(
            f"{label} is not bounded UTF-8 JSON: {error}"
        ) from error
    if not isinstance(value, dict):
        raise EvidenceSupportError(f"{label} is not a JSON object")
    return value


def load_bounded_repository_json_object(
    repository_root: pathlib.Path,
    relative_path: str | pathlib.PurePosixPath,
    *,
    label: str,
    maximum_bytes: int,
    budget: BoundedReadBudget | None = None,
    require_owner_controlled: bool = False,
) -> dict[str, Any]:
    """Load one bounded, stable UTF-8 JSON object from the repository."""

    raw = read_bounded_repository_bytes(
        repository_root,
        relative_path,
        label=label,
        maximum_bytes=maximum_bytes,
        budget=budget,
        require_owner_controlled=require_owner_controlled,
    )
    return decode_strict_json_object(raw, label=label)


def load_qualification_artifact(
    path: pathlib.Path,
    *,
    expected_sha256: str,
    expected_bytes: int,
    repository_root: pathlib.Path,
    schema_path: pathlib.Path | None = None,
    artifact_budget: BoundedReadBudget | None = None,
    schema_budget: BoundedReadBudget | None = None,
) -> dict[str, Any]:
    """Load and structurally validate one case- or predicate-scoped artifact.

    Semantic equality with a report fact is intentionally checked by the
    completion evaluator because that evaluator owns the expected case,
    iteration, role, subject, predicate, and current source manifest.
    """

    if re.fullmatch(r"[0-9a-f]{64}", expected_sha256) is None:
        raise EvidenceSupportError("qualification artifact expected digest is invalid")
    if (
        not isinstance(expected_bytes, int)
        or isinstance(expected_bytes, bool)
        or expected_bytes < 1
        or expected_bytes > MAXIMUM_QUALIFICATION_ARTIFACT_BYTES
    ):
        raise EvidenceSupportError(
            "qualification artifact recorded byte count is invalid or exceeds "
            f"{MAXIMUM_QUALIFICATION_ARTIFACT_BYTES} bytes"
        )
    if not repository_root.is_absolute() or not path.is_absolute():
        raise EvidenceSupportError(
            "qualification artifact and repository paths must be absolute"
        )
    try:
        relative_path = pathlib.PurePosixPath(
            path.relative_to(repository_root).as_posix()
        )
    except ValueError as error:
        raise EvidenceSupportError(
            "qualification artifact path is outside the repository"
        ) from error
    descriptor = _open_repository_relative_file(repository_root, relative_path)
    verification_descriptor: int | None = None
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise EvidenceSupportError("qualification artifact is not a regular file")
        if before.st_uid != os.geteuid():
            raise EvidenceSupportError(
                "qualification artifact is not owned by the current effective user"
            )
        if before.st_nlink != 1:
            raise EvidenceSupportError(
                "qualification artifact does not have exactly one hard link"
            )
        if stat.S_IMODE(before.st_mode) != 0o444:
            raise EvidenceSupportError(
                "qualification artifact mode is not exactly 0444"
            )
        if before.st_size != expected_bytes:
            raise EvidenceSupportError(
                "qualification artifact bytes do not match the recorded byte count"
            )
        if before.st_size > MAXIMUM_QUALIFICATION_ARTIFACT_BYTES:
            raise EvidenceSupportError(
                "qualification artifact exceeds "
                f"{MAXIMUM_QUALIFICATION_ARTIFACT_BYTES} bytes"
            )
        if artifact_budget is not None:
            artifact_budget.ensure_capacity(
                before.st_size,
                "qualification artifact",
            )
        raw_parts: list[bytes] = []
        total = 0
        while True:
            next_read_bytes = MAXIMUM_QUALIFICATION_ARTIFACT_BYTES + 1 - total
            if artifact_budget is not None:
                next_read_bytes = min(
                    next_read_bytes,
                    artifact_budget.remaining_bytes + 1,
                )
            block = os.read(descriptor, min(64 * 1024, next_read_bytes))
            if not block:
                break
            raw_parts.append(block)
            total += len(block)
            if total > MAXIMUM_QUALIFICATION_ARTIFACT_BYTES:
                raise EvidenceSupportError(
                    "qualification artifact exceeds "
                    f"{MAXIMUM_QUALIFICATION_ARTIFACT_BYTES} bytes while reading"
                )
            if artifact_budget is not None:
                artifact_budget.consume(len(block), "qualification artifact")
        after = os.fstat(descriptor)
        stable_fields_before = (
            before.st_dev,
            before.st_ino,
            before.st_mode,
            before.st_uid,
            before.st_nlink,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        )
        stable_fields_after = (
            after.st_dev,
            after.st_ino,
            after.st_mode,
            after.st_uid,
            after.st_nlink,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        )
        if stable_fields_before != stable_fields_after or total != before.st_size:
            raise EvidenceSupportError(
                "qualification artifact changed during its bounded read"
            )
        verification_descriptor = _open_repository_relative_file(
            repository_root,
            relative_path,
        )
        current_path = os.fstat(verification_descriptor)
        stable_fields_current_path = (
            current_path.st_dev,
            current_path.st_ino,
            current_path.st_mode,
            current_path.st_uid,
            current_path.st_nlink,
            current_path.st_size,
            current_path.st_mtime_ns,
            current_path.st_ctime_ns,
        )
        if stable_fields_current_path != stable_fields_after:
            raise EvidenceSupportError(
                "qualification artifact pathname no longer names the opened file"
            )
    except OSError as error:
        raise EvidenceSupportError(f"qualification artifact read failed: {error}") from error
    finally:
        try:
            if verification_descriptor is not None:
                os.close(verification_descriptor)
        finally:
            os.close(descriptor)
    raw = b"".join(raw_parts)
    if hashlib.sha256(raw).hexdigest() != expected_sha256:
        raise EvidenceSupportError(
            "qualification artifact bytes do not match the referenced SHA-256"
        )
    value = decode_strict_json_object(raw, label="qualification artifact")
    if schema_path is None:
        schema_path = (
            pathlib.Path(__file__).resolve().parent.parent
            / "schemas/p10-privileged-filesystem-artifact-binding.schema.json"
        )
    try:
        from jsonschema import Draft202012Validator

        canonical_repository = repository_root.resolve(strict=True)
        canonical_schema = schema_path.resolve(strict=True)
        schema_relative = pathlib.PurePosixPath(
            canonical_schema.relative_to(canonical_repository).as_posix()
        )
        schema = load_bounded_repository_json_object(
            canonical_repository,
            schema_relative,
            label="qualification artifact schema",
            maximum_bytes=MAXIMUM_QUALIFICATION_SCHEMA_BYTES,
            budget=schema_budget,
        )
        Draft202012Validator.check_schema(schema)
        schema_errors = sorted(
            Draft202012Validator(schema).iter_errors(value),
            key=lambda error: tuple(str(part) for part in error.absolute_path),
        )
    except ImportError as error:
        raise EvidenceSupportError(
            "qualification artifact schema runtime is unavailable"
        ) from error
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
        raise EvidenceSupportError(
            f"qualification artifact schema cannot be enforced: {error}"
        ) from error
    if schema_errors:
        first = schema_errors[0]
        location = ".".join(str(part) for part in first.absolute_path) or "<root>"
        raise EvidenceSupportError(
            "qualification artifact schema error at "
            f"{location}: {first.message}"
        )
    required = {
        "schema_version",
        "qualification",
        "evidence_id",
        "source_manifest",
        "scope",
        "fact_sha256",
        "claim",
    }
    if not isinstance(value, dict) or set(value) != required:
        raise EvidenceSupportError("qualification artifact field set is not exact")
    if value.get("schema_version") != QUALIFICATION_ARTIFACT_BINDING_SCHEMA_VERSION:
        raise EvidenceSupportError("qualification artifact binding schema is unsupported")
    if value.get("qualification") != QUALIFICATION_ARTIFACT_NAME:
        raise EvidenceSupportError("qualification artifact has the wrong qualification")
    evidence_id = _nonplaceholder_binding_text(value.get("evidence_id"), "evidence id")
    if re.fullmatch(r"EVID-[A-Za-z0-9][A-Za-z0-9._-]{0,250}", evidence_id) is None:
        raise EvidenceSupportError("qualification artifact evidence id is invalid")
    manifest = value.get("source_manifest")
    if not isinstance(manifest, dict) or set(manifest) != {
        "schema_version",
        "sha256",
        "file_count",
        "bytes",
    }:
        raise EvidenceSupportError("qualification artifact source manifest is invalid")
    if (
        manifest.get("schema_version") != MANIFEST_SCHEMA_VERSION
        or not isinstance(manifest.get("sha256"), str)
        or re.fullmatch(r"[0-9a-f]{64}", manifest["sha256"]) is None
        or not isinstance(manifest.get("file_count"), int)
        or isinstance(manifest.get("file_count"), bool)
        or manifest["file_count"] < 1
        or not isinstance(manifest.get("bytes"), int)
        or isinstance(manifest.get("bytes"), bool)
        or manifest["bytes"] < 1
    ):
        raise EvidenceSupportError("qualification artifact source manifest is incomplete")

    scope = value.get("scope")
    if not isinstance(scope, dict) or set(scope) != {
        "case_id",
        "role",
        "iteration",
        "subject",
        "predicate",
    }:
        raise EvidenceSupportError("qualification artifact scope field set is not exact")
    role = scope.get("role")
    if role not in QUALIFICATION_ARTIFACT_ROLES:
        raise EvidenceSupportError("qualification artifact role is unsupported")
    iteration = scope.get("iteration")
    if iteration is not None and (
        not isinstance(iteration, int)
        or isinstance(iteration, bool)
        or iteration < 1
    ):
        raise EvidenceSupportError("qualification artifact iteration is invalid")
    case_id = scope.get("case_id")
    subject = scope.get("subject")
    predicate = scope.get("predicate")
    if role == "qualification_context":
        if any(value is not None for value in (case_id, iteration, subject, predicate)):
            raise EvidenceSupportError(
                "qualification context artifact has scoped fields"
            )
    elif role == "formal_argument":
        if case_id is not None or iteration is not None or subject is not None:
            raise EvidenceSupportError("formal artifact has case-scoped fields")
        _nonplaceholder_binding_text(predicate, "formal predicate")
    else:
        _nonplaceholder_binding_text(case_id, "case id")
        if predicate is not None:
            raise EvidenceSupportError("case artifact has a formal predicate")
        if role in {"case_result", "barrier"}:
            if iteration is None:
                raise EvidenceSupportError(
                    "qualification artifact execution role has no iteration"
                )
        elif iteration is not None:
            raise EvidenceSupportError(
                "qualification artifact nonexecution role has an iteration"
            )
        if role in QUALIFICATION_ARTIFACT_SUBJECT_ROLES:
            _nonplaceholder_binding_text(subject, "scope subject")
        elif subject is not None:
            raise EvidenceSupportError(
                "qualification artifact role does not accept a subject"
            )

    fact_hash = value.get("fact_sha256")
    if (
        not isinstance(fact_hash, str)
        or re.fullmatch(r"[0-9a-f]{64}", fact_hash) is None
        or len(set(fact_hash)) == 1
    ):
        raise EvidenceSupportError("qualification artifact fact digest is invalid")
    _nonplaceholder_binding_text(value.get("claim"), "claim")
    return value


def sha256_file(
    path: pathlib.Path,
    *,
    maximum_bytes: int | None = None,
    budget: BoundedReadBudget | None = None,
    label: str | None = None,
) -> tuple[str, int]:
    digest = hashlib.sha256()
    total = 0
    item_label = label or f"file {path}"
    with path.open("rb") as stream:
        metadata = os.fstat(stream.fileno())
        if maximum_bytes is not None and metadata.st_size > maximum_bytes:
            raise EvidenceSupportError(
                f"file exceeds {maximum_bytes} bytes: {path}"
            )
        if budget is not None:
            budget.ensure_capacity(metadata.st_size, item_label)
        while True:
            next_read_bytes = 1024 * 1024
            if maximum_bytes is not None:
                next_read_bytes = min(
                    next_read_bytes,
                    maximum_bytes + 1 - total,
                )
            if budget is not None:
                next_read_bytes = min(
                    next_read_bytes,
                    budget.remaining_bytes + 1,
                )
            block = stream.read(next_read_bytes)
            if not block:
                break
            total += len(block)
            if maximum_bytes is not None and total > maximum_bytes:
                raise EvidenceSupportError(f"file exceeds {maximum_bytes} bytes: {path}")
            if budget is not None:
                budget.consume(len(block), item_label)
            digest.update(block)
    return digest.hexdigest(), total


def sha256_bounded_repository_file(
    repository_root: pathlib.Path,
    relative_path: str | pathlib.PurePosixPath,
    *,
    label: str,
    maximum_bytes: int,
    budget: BoundedReadBudget | None = None,
) -> tuple[str, int]:
    """Hash one stable regular repository file through descriptor-relative opens."""

    if maximum_bytes <= 0:
        raise EvidenceSupportError(f"{label} has an invalid file read bound")
    if not repository_root.is_absolute():
        raise EvidenceSupportError(f"{label} repository root is not absolute")
    pure_relative = _strict_repository_relative_path(relative_path, label=label)
    descriptor = _open_repository_relative_file(repository_root, pure_relative)
    verification_descriptor: int | None = None
    digest = hashlib.sha256()
    total = 0
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise EvidenceSupportError(f"{label} is not a regular file")
        if before.st_size > maximum_bytes:
            raise EvidenceSupportError(
                f"{label} exceeds its {maximum_bytes}-byte file read bound"
            )
        if budget is not None:
            budget.ensure_capacity(before.st_size, label)

        while True:
            next_read_bytes = maximum_bytes + 1 - total
            if budget is not None:
                next_read_bytes = min(
                    next_read_bytes,
                    budget.remaining_bytes + 1,
                )
            block = os.read(descriptor, min(1024 * 1024, next_read_bytes))
            if not block:
                break
            total += len(block)
            if total > maximum_bytes:
                raise EvidenceSupportError(
                    f"{label} exceeds its {maximum_bytes}-byte file read bound"
                )
            if budget is not None:
                budget.consume(len(block), label)
            digest.update(block)

        after = os.fstat(descriptor)
        stable_before = (
            before.st_dev,
            before.st_ino,
            before.st_mode,
            before.st_uid,
            before.st_nlink,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        )
        stable_after = (
            after.st_dev,
            after.st_ino,
            after.st_mode,
            after.st_uid,
            after.st_nlink,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        )
        if stable_before != stable_after or total != before.st_size:
            raise EvidenceSupportError(f"{label} changed during its bounded read")

        verification_descriptor = _open_repository_relative_file(
            repository_root,
            pure_relative,
        )
        current = os.fstat(verification_descriptor)
        stable_current = (
            current.st_dev,
            current.st_ino,
            current.st_mode,
            current.st_uid,
            current.st_nlink,
            current.st_size,
            current.st_mtime_ns,
            current.st_ctime_ns,
        )
        if stable_current != stable_after:
            raise EvidenceSupportError(
                f"{label} pathname no longer names the opened file"
            )
    except OSError as error:
        raise EvidenceSupportError(f"{label} read failed: {error}") from error
    finally:
        try:
            if verification_descriptor is not None:
                os.close(verification_descriptor)
        finally:
            os.close(descriptor)
    return digest.hexdigest(), total


def sha256_bounded_regular_file(
    path: pathlib.Path,
    *,
    label: str,
    maximum_bytes: int,
    budget: BoundedReadBudget | None = None,
) -> tuple[str, int]:
    """Hash one stable regular file with no final symlink and real byte bounds."""

    if maximum_bytes <= 0:
        raise EvidenceSupportError(f"{label} has an invalid file read bound")
    try:
        before = path.lstat()
    except OSError as error:
        raise EvidenceSupportError(f"{label} is unavailable: {error}") from error
    if stat.S_ISLNK(before.st_mode):
        raise EvidenceSupportError(f"{label} is a symbolic link")
    if not stat.S_ISREG(before.st_mode):
        raise EvidenceSupportError(f"{label} is not a regular file")
    if before.st_size > maximum_bytes:
        raise EvidenceSupportError(
            f"{label} exceeds its {maximum_bytes}-byte file read bound"
        )
    if budget is not None:
        budget.ensure_capacity(before.st_size, label)

    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise EvidenceSupportError(f"{label} cannot be opened: {error}") from error
    digest = hashlib.sha256()
    total = 0
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise EvidenceSupportError(f"{label} changed before its bounded read")
        while True:
            next_read_bytes = maximum_bytes + 1 - total
            if budget is not None:
                next_read_bytes = min(
                    next_read_bytes,
                    budget.remaining_bytes + 1,
                )
            block = os.read(descriptor, min(1024 * 1024, next_read_bytes))
            if not block:
                break
            total += len(block)
            if total > maximum_bytes:
                raise EvidenceSupportError(
                    f"{label} exceeds its {maximum_bytes}-byte file read bound"
                )
            if budget is not None:
                budget.consume(len(block), label)
            digest.update(block)
        after = os.fstat(descriptor)
    except OSError as error:
        raise EvidenceSupportError(f"{label} read failed: {error}") from error
    finally:
        os.close(descriptor)

    try:
        current = path.lstat()
    except OSError as error:
        raise EvidenceSupportError(
            f"{label} pathname changed after its bounded read: {error}"
        ) from error
    stable_fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_uid",
        "st_nlink",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    if (
        any(getattr(before, field) != getattr(after, field) for field in stable_fields)
        or any(getattr(before, field) != getattr(current, field) for field in stable_fields)
        or total != before.st_size
    ):
        raise EvidenceSupportError(f"{label} changed during its bounded read")
    return digest.hexdigest(), total


def _manifest_paths(
    root: pathlib.Path,
    excluded_paths: frozenset[str] = frozenset(),
) -> Iterable[pathlib.Path]:
    selected: set[pathlib.Path] = set()
    entries_seen = 0
    directory_flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_DIRECTORY", 0)
    )

    def include(path: pathlib.Path) -> None:
        relative = path.relative_to(root).as_posix()
        if relative in excluded_paths:
            return
        if path in selected:
            return
        if len(selected) >= MAXIMUM_MANIFEST_FILES:
            raise EvidenceSupportError(
                f"source manifest exceeds {MAXIMUM_MANIFEST_FILES} files"
            )
        selected.add(path)

    def visit(
        directory_descriptor: int,
        relative_directory: pathlib.PurePosixPath,
        depth: int,
    ) -> None:
        nonlocal entries_seen
        if depth > MAXIMUM_MANIFEST_DEPTH:
            raise EvidenceSupportError(
                "source manifest traversal exceeds its directory depth bound"
            )
        directory_before = os.fstat(directory_descriptor)
        if not stat.S_ISDIR(directory_before.st_mode):
            raise EvidenceSupportError(
                "source manifest traversal opened a non-directory"
            )
        try:
            with os.scandir(directory_descriptor) as iterator:
                for directory_entry in iterator:
                    entries_seen += 1
                    if entries_seen > MAXIMUM_MANIFEST_ENTRIES:
                        raise EvidenceSupportError(
                            "source manifest traversal exceeds "
                            f"{MAXIMUM_MANIFEST_ENTRIES} entries"
                        )
                    name = directory_entry.name
                    relative = relative_directory / name
                    try:
                        encoded_relative = relative.as_posix().encode(
                            "utf-8",
                            errors="strict",
                        )
                    except UnicodeEncodeError as error:
                        raise EvidenceSupportError(
                            "source manifest path is not strict UTF-8"
                        ) from error
                    if len(encoded_relative) > 4096:
                        raise EvidenceSupportError(
                            "source manifest path exceeds its byte bound"
                        )
                    if any(part in IGNORED_MANIFEST_NAMES for part in relative.parts):
                        continue
                    metadata = os.stat(
                        name,
                        dir_fd=directory_descriptor,
                        follow_symlinks=False,
                    )
                    if stat.S_ISLNK(metadata.st_mode):
                        raise EvidenceSupportError(
                            f"manifest content is a symbolic link: {relative}"
                        )
                    if stat.S_ISREG(metadata.st_mode):
                        include(root / relative.as_posix())
                        continue
                    if not stat.S_ISDIR(metadata.st_mode):
                        raise EvidenceSupportError(
                            "manifest content is not a regular file or directory: "
                            f"{relative}"
                        )
                    next_depth = depth + 1
                    if next_depth > MAXIMUM_MANIFEST_DEPTH:
                        raise EvidenceSupportError(
                            "source manifest traversal exceeds its directory depth bound"
                        )
                    child_descriptor: int | None = None
                    try:
                        child_descriptor = os.open(
                            name,
                            directory_flags,
                            dir_fd=directory_descriptor,
                        )
                        opened = os.fstat(child_descriptor)
                        if _stable_tree_metadata(opened) != _stable_tree_metadata(
                            metadata
                        ):
                            raise EvidenceSupportError(
                                "source manifest directory changed before traversal: "
                                f"{relative}"
                            )
                        visit(child_descriptor, relative, next_depth)
                        after = os.fstat(child_descriptor)
                        current = os.stat(
                            name,
                            dir_fd=directory_descriptor,
                            follow_symlinks=False,
                        )
                        if (
                            _stable_tree_metadata(after)
                            != _stable_tree_metadata(metadata)
                            or _stable_tree_metadata(current)
                            != _stable_tree_metadata(metadata)
                        ):
                            raise EvidenceSupportError(
                                "source manifest directory changed during traversal: "
                                f"{relative}"
                            )
                    finally:
                        if child_descriptor is not None:
                            os.close(child_descriptor)
        except OSError as error:
            raise EvidenceSupportError(
                "source manifest directory cannot be enumerated safely: "
                f"{relative_directory}: {error}"
            ) from error
        directory_after = os.fstat(directory_descriptor)
        if _stable_tree_metadata(directory_after) != _stable_tree_metadata(
            directory_before
        ):
            raise EvidenceSupportError(
                "source manifest directory changed during traversal: "
                f"{relative_directory}"
            )

    for relative in MANIFEST_TARGETS:
        pure_relative = _strict_repository_relative_path(
            relative,
            label="manifest target",
        )
        descriptors: list[int] = []
        edges: list[tuple[int, str, os.stat_result]] = []
        try:
            root_descriptor = os.open(root, directory_flags)
            descriptors.append(root_descriptor)
            root_identity = os.fstat(root_descriptor)
            parent_descriptor = root_descriptor
            target_missing = False
            for component in pure_relative.parts[:-1]:
                try:
                    component_identity = os.stat(
                        component,
                        dir_fd=parent_descriptor,
                        follow_symlinks=False,
                    )
                except FileNotFoundError:
                    target_missing = True
                    break
                if not stat.S_ISDIR(component_identity.st_mode):
                    raise EvidenceSupportError(
                        "manifest target parent is not a directory: "
                        f"{pure_relative}"
                    )
                child_descriptor = os.open(
                    component,
                    directory_flags,
                    dir_fd=parent_descriptor,
                )
                opened = os.fstat(child_descriptor)
                if _stable_tree_metadata(opened) != _stable_tree_metadata(
                    component_identity
                ):
                    os.close(child_descriptor)
                    raise EvidenceSupportError(
                        "manifest target parent changed before traversal: "
                        f"{pure_relative}"
                    )
                edges.append((parent_descriptor, component, component_identity))
                descriptors.append(child_descriptor)
                parent_descriptor = child_descriptor
            if target_missing:
                continue

            target_name = pure_relative.parts[-1]
            try:
                metadata = os.stat(
                    target_name,
                    dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                continue
            if stat.S_ISLNK(metadata.st_mode):
                raise EvidenceSupportError(
                    f"manifest target is a symbolic link: {relative}"
                )
            if stat.S_ISREG(metadata.st_mode):
                include(root / pure_relative.as_posix())
            elif stat.S_ISDIR(metadata.st_mode):
                target_descriptor = os.open(
                    target_name,
                    directory_flags,
                    dir_fd=parent_descriptor,
                )
                opened = os.fstat(target_descriptor)
                if _stable_tree_metadata(opened) != _stable_tree_metadata(metadata):
                    os.close(target_descriptor)
                    raise EvidenceSupportError(
                        f"manifest target changed before traversal: {relative}"
                    )
                edges.append((parent_descriptor, target_name, metadata))
                descriptors.append(target_descriptor)
                visit(target_descriptor, pure_relative, len(pure_relative.parts))
            else:
                raise EvidenceSupportError(
                    "manifest target is not a regular file or directory: "
                    f"{relative}"
                )

            for parent, name, expected in edges:
                current = os.stat(
                    name,
                    dir_fd=parent,
                    follow_symlinks=False,
                )
                if _stable_tree_metadata(current) != _stable_tree_metadata(expected):
                    raise EvidenceSupportError(
                        f"manifest target pathname changed during traversal: {relative}"
                    )
            current_root = os.stat(root, follow_symlinks=False)
            if _stable_tree_metadata(current_root) != _stable_tree_metadata(
                root_identity
            ):
                raise EvidenceSupportError(
                    "manifest repository root changed during traversal"
                )
        except OSError as error:
            raise EvidenceSupportError(
                f"manifest target cannot be inspected safely: {relative}: {error}"
            ) from error
        finally:
            for descriptor in reversed(descriptors):
                os.close(descriptor)
    yield from sorted(selected, key=lambda value: value.relative_to(root).as_posix())


def _source_manifest_snapshot(
    root: pathlib.Path,
    budget: BoundedReadBudget,
    excluded_paths: frozenset[str] = frozenset(),
) -> tuple[list[dict[str, Any]], int]:
    files: list[dict[str, Any]] = []
    total = 0
    snapshot_budget = BoundedReadBudget(
        MAXIMUM_MANIFEST_TOTAL_BYTES,
        "source manifest snapshot",
    )
    for path in _manifest_paths(root, excluded_paths):
        relative = path.relative_to(root).as_posix()
        digest, byte_count = sha256_bounded_repository_file(
            root,
            relative,
            label=f"source manifest file {relative}",
            maximum_bytes=MAXIMUM_MANIFEST_FILE_BYTES,
            budget=snapshot_budget,
        )
        budget.consume(byte_count, f"source manifest file {relative}")
        total += byte_count
        if total > MAXIMUM_MANIFEST_TOTAL_BYTES:
            raise EvidenceSupportError(
                f"manifest exceeds {MAXIMUM_MANIFEST_TOTAL_BYTES} total bytes"
            )
        files.append({
            "path": relative,
            "bytes": byte_count,
            "sha256": digest,
        })
    return files, total


def source_manifest(
    root: pathlib.Path,
    *,
    excluded_paths: Iterable[str] = (),
) -> dict[str, Any]:
    root = root.resolve(strict=True)
    canonical_exclusions: set[str] = set()
    for raw_path in excluded_paths:
        pure_path = _strict_repository_relative_path(
            raw_path,
            label="source manifest exclusion",
        )
        canonical_exclusions.add(pure_path.as_posix())
    exclusions = frozenset(canonical_exclusions)
    budget = BoundedReadBudget(
        MAXIMUM_MANIFEST_TOTAL_BYTES * 2,
        "two-pass source manifest",
    )
    files, total = _source_manifest_snapshot(root, budget, exclusions)
    if not files:
        raise EvidenceSupportError(f"source manifest is empty: {root}")
    if total < 1:
        raise EvidenceSupportError(f"source manifest has no source bytes: {root}")
    verification_files, verification_total = _source_manifest_snapshot(
        root,
        budget,
        exclusions,
    )
    if files != verification_files or total != verification_total:
        raise EvidenceSupportError("source manifest changed during its two-pass read")
    payload = {"schema_version": MANIFEST_SCHEMA_VERSION, "files": files}
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return {
        "schema_version": MANIFEST_SCHEMA_VERSION,
        "sha256": hashlib.sha256(canonical).hexdigest(),
        "file_count": len(files),
        "bytes": total,
    }


def parse_xctest_summaries(text: str) -> list[dict[str, int]]:
    summaries: list[dict[str, int]] = []
    for match in XCTEST_SUMMARY.finditer(text):
        summaries.append({
            "executed": int(match.group("executed")),
            "skipped": int(match.group("skipped") or 0),
            "failures": int(match.group("failures")),
        })
    return summaries


def atomic_write(path: pathlib.Path, data: bytes, *, final_mode: int = 0o444) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = pathlib.Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), final_mode)
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def atomic_write_json(path: pathlib.Path, value: Any, *, final_mode: int = 0o444) -> None:
    encoded = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
    atomic_write(path, encoded, final_mode=final_mode)
