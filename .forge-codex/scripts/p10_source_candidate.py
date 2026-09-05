#!/usr/bin/env python3
"""Validate unchanged source candidates carried by evidence-only delivery commits."""
from __future__ import annotations

import pathlib
import re
from typing import Any

from evidence_support import (
    EvidenceSupportError, IGNORED_MANIFEST_NAMES, MANIFEST_TARGETS,
    current_git_head, run_bounded_readonly_command, source_manifest,
)

# Include complete native project/workspace and resource trees when checking
# cleanliness, even where the older manifest names individual project files.
CONTROLLED_PATHS = tuple(dict.fromkeys((*MANIFEST_TARGETS, "Assets", "ForgeConductor.xcodeproj", "ForgeConductor.xcworkspace", "Package.resolved", ".swiftpm")))
MAXIMUM_PATH_BYTES = 1024 * 1024
MAXIMUM_PATH_COUNT = 10000


def controlled(path: str) -> bool:
    return any(path == target or path.startswith(target + "/") for target in CONTROLLED_PATHS)


def _git(repository: pathlib.Path, *arguments: str) -> bytes:
    code, output, errors = run_bounded_readonly_command(
        repository, "P10 source candidate Git validation", ["/usr/bin/git", *arguments],
        timeout_seconds=10, maximum_output_bytes=MAXIMUM_PATH_BYTES,
    )
    if code != 0 or errors:
        raise EvidenceSupportError("P10 source candidate Git validation failed")
    return output


def _paths(raw: bytes) -> list[str]:
    try:
        values = [value.decode("utf-8", errors="strict") for value in raw.split(b"\0") if value]
    except UnicodeDecodeError as error:
        raise EvidenceSupportError("P10 source candidate contains a non-UTF-8 path") from error
    if len(values) > MAXIMUM_PATH_COUNT:
        raise EvidenceSupportError("P10 source candidate path count exceeds its bound")
    return values


def _delivery_path(path: str) -> bool:
    pure = pathlib.PurePosixPath(path)
    return (
        pure.as_posix() == path and not pure.is_absolute() and ".." not in pure.parts
        and len(path.encode("utf-8")) <= 4096 and not controlled(path)
        and pure.parts[:2] in {(".forge-codex", "evidence"), (".forge-codex", "state")}
    )


def validate_source_candidate(
    repository: pathlib.Path,
    candidate_sha: Any,
    delivery_sha: Any,
    recorded_manifest: Any,
    current_manifest: Any,
) -> None:
    """Require exact controlled inputs and an actual evidence-only ancestry path.

    Net tree equality alone is insufficient: each intervening commit and merge
    parent diff is inspected, so an input edit followed by a revert is rejected.
    """
    repository = repository.resolve(strict=True)
    if not all(isinstance(value, str) and re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", value) for value in (candidate_sha, delivery_sha)):
        raise EvidenceSupportError("P10 source candidate or delivery SHA is malformed")
    if current_git_head(repository) != delivery_sha:
        raise EvidenceSupportError("P10 delivery SHA is not current Git HEAD")
    if recorded_manifest != current_manifest or source_manifest(repository) != current_manifest:
        raise EvidenceSupportError("P10 source candidate controlled manifest changed")
    _git(repository, "merge-base", "--is-ancestor", candidate_sha, delivery_sha)
    # NUL porcelain includes the second pathname of a rename. Any reported
    # controlled change fails; only manifest-ignored cache names are disregarded.
    status = _paths(_git(repository, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching", "--", *CONTROLLED_PATHS))
    for entry in status:
        path = entry[3:] if len(entry) >= 3 and entry[2] == " " else entry
        parts = pathlib.PurePosixPath(path).parts
        generated_user_state = entry.startswith("!! ") and "xcuserdata" in parts and parts[0] in {"ForgeConductor.xcodeproj", "ForgeConductor.xcworkspace", ".swiftpm"}
        if not generated_user_state and not any(part in IGNORED_MANIFEST_NAMES for part in parts):
            raise EvidenceSupportError("P10 source candidate has dirty controlled inputs: " + path)
    changes = _paths(_git(repository, "log", "-m", "--format=", "--name-only", "--no-renames", "-z", f"{candidate_sha}..{delivery_sha}"))
    for path in changes:
        if not _delivery_path(path):
            raise EvidenceSupportError("P10 delivery history changed a controlled or non-evidence path: " + path)
