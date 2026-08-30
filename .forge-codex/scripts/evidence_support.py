#!/usr/bin/env python3
"""Shared deterministic and bounded helpers for command-backed evidence."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import stat
import tempfile
from typing import Any, Iterable


MANIFEST_SCHEMA_VERSION = 1
MAXIMUM_MANIFEST_FILE_BYTES = 64 * 1024 * 1024
MAXIMUM_MANIFEST_TOTAL_BYTES = 512 * 1024 * 1024
MANIFEST_TARGETS = (
    "Package.swift",
    "ForgeConductor.xcodeproj/project.pbxproj",
    "Sources",
    "Tests",
    ".forge-codex/scripts/record_command.py",
    ".forge-codex/scripts/evidence_support.py",
    ".forge-codex/scripts/check_p10_completion.py",
    ".forge-codex/scripts/check_p10_cli_compatibility.py",
    ".forge-codex/scripts/check_p10_manager_http_compatibility.py",
    ".forge-codex/scripts/check_p10_protocol_compatibility.py",
    ".forge-codex/scripts/test_evidence_controls.py",
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


class EvidenceSupportError(RuntimeError):
    """Raised when evidence cannot be produced within its declared bounds."""


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
