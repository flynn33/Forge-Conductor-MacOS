#!/usr/bin/env python3
"""Resolve local and published checkpoint identity without conflating branches."""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path
from typing import Callable, Optional, Sequence, Tuple


CommandRunner = Callable[[Path, Sequence[str], int], Tuple[Optional[int], str]]
SHA_PATTERN = re.compile(r"[0-9a-f]{40}")


def run_command(
    repository: Path,
    arguments: Sequence[str],
    timeout_seconds: int,
) -> tuple[int | None, str]:
    try:
        result = subprocess.run(
            list(arguments),
            cwd=repository,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=timeout_seconds,
        )
    except (OSError, subprocess.SubprocessError):
        return None, ""
    return result.returncode, result.stdout.strip()


def _single_value(
    repository: Path,
    runner: CommandRunner,
    arguments: Sequence[str],
) -> str | None:
    return_code, output = runner(repository, arguments, 10)
    if return_code != 0 or not output or "\n" in output or "\r" in output:
        return None
    return output


def _commit_sha(value: str | None) -> str | None:
    return value if value is not None and SHA_PATTERN.fullmatch(value) else None


def _configured_publication_target(
    repository: Path,
    runner: CommandRunner,
    active_branch: str | None,
) -> tuple[str | None, str | None, str]:
    if not active_branch:
        return None, None, "no_active_branch"

    remote_code, remote_output = runner(
        repository,
        ["git", "config", "--get-all", f"branch.{active_branch}.remote"],
        10,
    )
    merge_code, merge_output = runner(
        repository,
        ["git", "config", "--get-all", f"branch.{active_branch}.merge"],
        10,
    )
    remotes = remote_output.splitlines() if remote_code == 0 and remote_output else []
    merge_refs = merge_output.splitlines() if merge_code == 0 and merge_output else []
    if not remotes and not merge_refs:
        return None, None, "no_configured_upstream"
    if len(remotes) != 1 or len(merge_refs) != 1:
        return None, None, "ambiguous_upstream_configuration"

    remote = remotes[0]
    merge_ref = merge_refs[0]
    prefix = "refs/heads/"
    if not remote or remote == "." or not merge_ref.startswith(prefix):
        return None, None, "unsupported_upstream_configuration"
    publication_branch = merge_ref[len(prefix):]
    if not publication_branch:
        return None, None, "unsupported_upstream_configuration"
    return remote, publication_branch, "configured_upstream"


def resolve_checkpoint_identity(
    repository: Path,
    *,
    runner: CommandRunner = run_command,
) -> dict[str, object]:
    repository = repository.resolve()
    active_branch = _single_value(
        repository,
        runner,
        ["git", "branch", "--show-current"],
    )
    head_sha = _commit_sha(
        _single_value(repository, runner, ["git", "rev-parse", "HEAD"])
    )
    main_sha = _commit_sha(
        _single_value(repository, runner, ["git", "rev-parse", "origin/main"])
    )
    publication_remote, publication_branch, resolution = _configured_publication_target(
        repository,
        runner,
        active_branch,
    )

    remote_head_sha = None
    pull_request = None
    if resolution == "configured_upstream":
        if publication_remote != "origin":
            resolution = "unsupported_publication_remote"
        else:
            remote_head_sha = _commit_sha(
                _single_value(
                    repository,
                    runner,
                    [
                        "git",
                        "rev-parse",
                        f"refs/remotes/{publication_remote}/{publication_branch}",
                    ],
                )
            )
            if remote_head_sha is None:
                resolution = "publication_remote_head_missing"
            else:
                return_code, output = runner(
                    repository,
                    [
                        "gh",
                        "pr",
                        "list",
                        "--head",
                        publication_branch,
                        "--state",
                        "open",
                        "--limit",
                        "2",
                        "--json",
                        "number,state,isDraft,baseRefName,baseRefOid,headRefName,headRefOid,url",
                    ],
                    20,
                )
                try:
                    values = json.loads(output) if return_code == 0 else None
                except (TypeError, ValueError):
                    values = None
                if not isinstance(values, list):
                    resolution = "pull_request_readback_failed"
                elif len(values) == 0:
                    resolution = "open_pull_request_not_found"
                elif len(values) > 1:
                    resolution = "ambiguous_open_pull_requests"
                elif not isinstance(values[0], dict):
                    resolution = "pull_request_readback_failed"
                else:
                    pull_request = values[0]

    base_branch = (
        pull_request.get("baseRefName")
        if pull_request
        and isinstance(pull_request.get("baseRefName"), str)
        and pull_request.get("baseRefName")
        else "main"
    )
    base_sha = _commit_sha(
        _single_value(
            repository,
            runner,
            ["git", "rev-parse", f"refs/remotes/origin/{base_branch}"],
        )
    )
    readback_verified = bool(
        resolution == "configured_upstream"
        and pull_request
        and pull_request.get("state") == "OPEN"
        and pull_request.get("baseRefName") == base_branch
        and pull_request.get("baseRefOid") == base_sha
        and pull_request.get("headRefName") == publication_branch
        and pull_request.get("headRefOid") == head_sha
        and base_sha
        and remote_head_sha == head_sha
    )
    if pull_request is not None:
        resolution = "verified" if readback_verified else "pull_request_readback_mismatch"

    return {
        "active_branch": active_branch,
        "publication_remote": publication_remote,
        "publication_head_branch": publication_branch,
        "head_sha": head_sha,
        "base_branch": base_branch,
        "base_sha": base_sha,
        "main_branch": "main",
        "main_sha": main_sha,
        "remote_head_sha": remote_head_sha,
        "pull_request": pull_request,
        "identity_resolution": resolution,
        "github_readback_verified": readback_verified,
    }
