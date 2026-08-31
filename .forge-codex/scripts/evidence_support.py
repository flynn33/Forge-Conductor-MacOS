#!/usr/bin/env python3
"""Shared deterministic and bounded helpers for command-backed evidence."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import selectors
import stat
import subprocess
import tempfile
import time
from typing import Any, Iterable


MANIFEST_SCHEMA_VERSION = 1
EVIDENCE_CONTEXT_SCHEMA_VERSION = 1
QUALIFICATION_ARTIFACT_BINDING_SCHEMA_VERSION = 1
QUALIFICATION_ARTIFACT_NAME = "p10-privileged-filesystem"
MAXIMUM_QUALIFICATION_ARTIFACT_BYTES = 1024 * 1024
MAXIMUM_MANIFEST_FILE_BYTES = 64 * 1024 * 1024
MAXIMUM_MANIFEST_TOTAL_BYTES = 512 * 1024 * 1024
MANIFEST_TARGETS = (
    "Package.swift",
    "ForgeConductor.xcodeproj/project.pbxproj",
    "ForgeConductor.xcodeproj/xcshareddata/xcschemes/ForgeFilesystemQualification.xcscheme",
    "script",
    "Sources",
    "Tests",
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
    ".forge-codex/scripts/test_evidence_controls.py",
    ".forge-codex/schemas/p10-privileged-filesystem-artifact-binding.schema.json",
    ".forge-codex/schemas/p10-privileged-filesystem-h0-readiness.schema.json",
    ".forge-codex/schemas/p10-privileged-filesystem-admission-observation.schema.json",
    ".forge-codex/schemas/p10-privileged-filesystem-qualification-report.schema.json",
    ".forge-codex/templates/p10-privileged-filesystem-qualification-report.json",
    ".forge-codex/docs/PRIVILEGED_FILESYSTEM_QUALIFICATION.md",
    ".forge-codex/architecture/SECURITY_AND_PRIVACY.md",
    ".forge-codex/state/baseline",
)
IGNORED_MANIFEST_NAMES = {".DS_Store", "__pycache__"}
XCTEST_SUMMARY = re.compile(
    r"Executed (?P<executed>\d+) tests?, with "
    r"(?:(?P<skipped>\d+) tests? skipped and )?"
    r"(?P<failures>\d+) failures?"
)
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


def run_bounded_readonly_command(
    repository: pathlib.Path,
    label: str,
    command: list[str],
    *,
    timeout_seconds: float,
    maximum_output_bytes: int,
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
                streams[descriptor][1].append(block)
                total += len(block)
                if total > maximum_output_bytes:
                    exceeded = True
                    break
            if exceeded:
                break
        if timed_out or exceeded:
            process.kill()
        remaining = max(0.0, deadline - time.monotonic())
        try:
            return_code = process.wait(timeout=max(0.1, remaining))
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=1)
            timed_out = True
            return_code = process.returncode
    finally:
        selector.close()
        process.stdout.close()
        process.stderr.close()
    if timed_out:
        raise EvidenceSupportError(f"{label} exceeded its time bound")
    if exceeded:
        raise EvidenceSupportError(f"{label} exceeds its read bound")
    stdout = b"".join(streams[stdout_descriptor][1])
    stderr = b"".join(streams[stderr_descriptor][1])
    return return_code, stdout, stderr


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


def load_qualification_artifact(
    path: pathlib.Path,
    *,
    expected_sha256: str,
    expected_bytes: int,
    repository_root: pathlib.Path,
    schema_path: pathlib.Path | None = None,
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
        raw_parts: list[bytes] = []
        total = 0
        while True:
            block = os.read(descriptor, min(64 * 1024, MAXIMUM_QUALIFICATION_ARTIFACT_BYTES + 1 - total))
            if not block:
                break
            raw_parts.append(block)
            total += len(block)
            if total > MAXIMUM_QUALIFICATION_ARTIFACT_BYTES:
                raise EvidenceSupportError(
                    "qualification artifact exceeds "
                    f"{MAXIMUM_QUALIFICATION_ARTIFACT_BYTES} bytes while reading"
                )
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
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise EvidenceSupportError(
            f"qualification artifact is not bounded UTF-8 JSON: {error}"
        ) from error
    if schema_path is None:
        schema_path = (
            pathlib.Path(__file__).resolve().parent.parent
            / "schemas/p10-privileged-filesystem-artifact-binding.schema.json"
        )
    try:
        from jsonschema import Draft202012Validator

        schema = json.loads(schema_path.read_text(encoding="utf-8"))
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


def sha256_file(path: pathlib.Path, *, maximum_bytes: int | None = None) -> tuple[str, int]:
    digest = hashlib.sha256()
    total = 0
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            total += len(block)
            if maximum_bytes is not None and total > maximum_bytes:
                raise EvidenceSupportError(f"file exceeds {maximum_bytes} bytes: {path}")
            digest.update(block)
    return digest.hexdigest(), total


def _manifest_paths(root: pathlib.Path) -> Iterable[pathlib.Path]:
    selected: set[pathlib.Path] = set()
    for relative in MANIFEST_TARGETS:
        target = root / relative
        if not target.exists():
            continue
        if target.is_symlink():
            raise EvidenceSupportError(f"manifest target is a symbolic link: {relative}")
        if target.is_file():
            selected.add(target)
            continue
        if not target.is_dir():
            raise EvidenceSupportError(f"manifest target is not a regular file or directory: {relative}")
        for candidate in target.rglob("*"):
            if any(part in IGNORED_MANIFEST_NAMES for part in candidate.relative_to(root).parts):
                continue
            if candidate.is_symlink():
                raise EvidenceSupportError(
                    f"manifest content is a symbolic link: {candidate.relative_to(root)}"
                )
            if candidate.is_file():
                selected.add(candidate)
    yield from sorted(selected, key=lambda value: value.relative_to(root).as_posix())


def source_manifest(root: pathlib.Path) -> dict[str, Any]:
    root = root.resolve(strict=True)
    files: list[dict[str, Any]] = []
    total = 0
    for path in _manifest_paths(root):
        metadata = path.stat()
        if not stat.S_ISREG(metadata.st_mode):
            raise EvidenceSupportError(f"manifest content is not a regular file: {path}")
        if metadata.st_size > MAXIMUM_MANIFEST_FILE_BYTES:
            raise EvidenceSupportError(
                f"manifest file exceeds {MAXIMUM_MANIFEST_FILE_BYTES} bytes: {path}"
            )
        total += metadata.st_size
        if total > MAXIMUM_MANIFEST_TOTAL_BYTES:
            raise EvidenceSupportError(
                f"manifest exceeds {MAXIMUM_MANIFEST_TOTAL_BYTES} total bytes"
            )
        digest, byte_count = sha256_file(path, maximum_bytes=MAXIMUM_MANIFEST_FILE_BYTES)
        files.append({
            "path": path.relative_to(root).as_posix(),
            "bytes": byte_count,
            "sha256": digest,
        })
    if not files:
        raise EvidenceSupportError(f"source manifest is empty: {root}")
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
