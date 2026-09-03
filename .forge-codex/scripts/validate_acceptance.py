#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import stat
import sys
import uuid
from typing import Any

from evidence_support import (
    BoundedReadBudget,
    EvidenceSupportError,
    current_git_head,
    load_bounded_repository_json_object,
    sha256_bounded_repository_file,
    sha256_bounded_regular_file,
    source_manifest,
)
from p10_feature_evidence import validate_p10_feature_binding


MAXIMUM_CONTROL_JSON_FILE_BYTES = 1024 * 1024
MAXIMUM_CONTROL_JSON_TOTAL_BYTES = 64 * 1024 * 1024
MAXIMUM_G10_EVIDENCE_FILE_BYTES = 64 * 1024 * 1024
MAXIMUM_G10_EVIDENCE_TOTAL_BYTES = 512 * 1024 * 1024
MAXIMUM_EVIDENCE_FILE_BYTES = 16 * 1024 * 1024 * 1024
MAXIMUM_EVIDENCE_TOTAL_BYTES = 16 * 1024 * 1024 * 1024
MAXIMUM_PATH_BYTES = 4096
MAXIMUM_CRITERIA_OUTPUT_BYTES = 1024 * 1024
CRITERIA_OUTPUT_MODE = 0o600


def locate_repo(explicit: str | None) -> pathlib.Path:
    if explicit:
        return pathlib.Path(explicit).resolve()
    current = pathlib.Path.cwd().resolve()
    for candidate in (current, *current.parents):
        if (candidate / ".forge-codex").is_dir():
            return candidate
    raise SystemExit("repository not found")


def canonical_repository_path(
    repository: pathlib.Path,
    raw_path: Any,
    *,
    base: pathlib.Path,
    label: str,
) -> tuple[str, pathlib.Path]:
    """Return one strict repository-relative path and its lexical absolute path."""

    if not isinstance(raw_path, str) or not raw_path:
        raise EvidenceSupportError(f"{label} path is not a nonempty string")
    try:
        encoded = raw_path.encode("utf-8", errors="strict")
    except UnicodeEncodeError as error:
        raise EvidenceSupportError(f"{label} path is not UTF-8") from error
    candidate = pathlib.PurePosixPath(raw_path)
    if (
        b"\0" in encoded
        or len(encoded) > MAXIMUM_PATH_BYTES
        or "\\" in raw_path
        or candidate.as_posix() != raw_path
        or any(part in {"", ".", ".."} for part in candidate.parts)
    ):
        raise EvidenceSupportError(f"{label} path is not canonical")

    if candidate.is_absolute():
        absolute = pathlib.Path(raw_path)
    else:
        absolute = base.joinpath(*candidate.parts)
    try:
        relative = absolute.relative_to(repository)
    except ValueError as error:
        raise EvidenceSupportError(f"{label} path is outside the repository") from error
    relative_text = relative.as_posix()
    if (
        not relative_text
        or relative_text == "."
        or pathlib.PurePosixPath(relative_text).is_absolute()
        or any(part in {"", ".", ".."} for part in relative.parts)
        or repository.joinpath(*relative.parts) != absolute
    ):
        raise EvidenceSupportError(f"{label} path is not canonical repository content")
    return relative_text, absolute


def canonical_external_path(raw_path: Any, *, label: str) -> pathlib.Path:
    """Return one strict absolute external path without resolving its identity."""

    if not isinstance(raw_path, str) or not raw_path:
        raise EvidenceSupportError(f"{label} path is not a nonempty string")
    try:
        encoded = raw_path.encode("utf-8", errors="strict")
    except UnicodeEncodeError as error:
        raise EvidenceSupportError(f"{label} path is not UTF-8") from error
    candidate = pathlib.PurePosixPath(raw_path)
    if (
        b"\0" in encoded
        or len(encoded) > MAXIMUM_PATH_BYTES
        or "\\" in raw_path
        or not candidate.is_absolute()
        or raw_path.startswith("//")
        or candidate.as_posix() != raw_path
        or any(part in {"", ".", ".."} for part in candidate.parts)
    ):
        raise EvidenceSupportError(f"{label} path is not canonical absolute content")
    return pathlib.Path(raw_path)


def path_is_missing(path: pathlib.Path) -> bool:
    try:
        path.lstat()
    except (FileNotFoundError, NotADirectoryError):
        return True
    except OSError:
        return False
    return False


def stable_evidence_digest(
    repository: pathlib.Path,
    raw_path: Any,
    *,
    label: str,
    budget: BoundedReadBudget,
    require_repository_content: bool,
) -> tuple[pathlib.Path, str]:
    try:
        relative, absolute = canonical_repository_path(
            repository,
            raw_path,
            base=repository,
            label=label,
        )
    except EvidenceSupportError:
        if require_repository_content:
            raise
        absolute = canonical_external_path(raw_path, label=label)
        digest, _ = sha256_bounded_regular_file(
            absolute,
            label=label,
            maximum_bytes=MAXIMUM_EVIDENCE_FILE_BYTES,
            budget=budget,
        )
        return absolute, digest
    digest, _ = sha256_bounded_repository_file(
        repository,
        relative,
        label=label,
        maximum_bytes=(
            MAXIMUM_G10_EVIDENCE_FILE_BYTES
            if require_repository_content
            else MAXIMUM_EVIDENCE_FILE_BYTES
        ),
        budget=budget,
    )
    return absolute, digest


def _control_directory_identity(
    descriptor: int,
    *,
    label: str,
) -> tuple[int, int, int, int]:
    """Validate one owner-controlled directory and return its stable identity."""

    try:
        metadata = os.fstat(descriptor)
    except OSError as error:
        raise EvidenceSupportError(f"{label} cannot be inspected: {error}") from error
    if not stat.S_ISDIR(metadata.st_mode):
        raise EvidenceSupportError(f"{label} is not a directory")
    if metadata.st_uid != os.geteuid():
        raise EvidenceSupportError(f"{label} is not owned by the current effective user")
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        raise EvidenceSupportError(f"{label} is group- or world-writable")
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_uid,
        stat.S_IMODE(metadata.st_mode),
    )


def _open_control_directory(
    parent_descriptor: int | None,
    component: str | pathlib.Path,
    *,
    label: str,
) -> tuple[int, tuple[int, int, int, int]]:
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_DIRECTORY", 0)
    )
    try:
        if parent_descriptor is None:
            descriptor = os.open(component, flags)
        else:
            descriptor = os.open(component, flags, dir_fd=parent_descriptor)
    except OSError as error:
        raise EvidenceSupportError(
            f"{label} is unavailable or contains a symbolic link: {error}"
        ) from error
    try:
        identity = _control_directory_identity(descriptor, label=label)
    except Exception:
        os.close(descriptor)
        raise
    return descriptor, identity


def _validate_existing_criteria_output(
    directory_descriptor: int,
    filename: str,
) -> None:
    try:
        metadata = os.stat(
            filename,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
    except FileNotFoundError:
        return
    except OSError as error:
        raise EvidenceSupportError(
            f"criteria output cannot be inspected safely: {error}"
        ) from error
    if not stat.S_ISREG(metadata.st_mode):
        raise EvidenceSupportError("criteria output is not a regular non-symlink file")
    if metadata.st_uid != os.geteuid():
        raise EvidenceSupportError(
            "criteria output is not owned by the current effective user"
        )
    if metadata.st_nlink != 1:
        raise EvidenceSupportError("criteria output does not have exactly one hard link")
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        raise EvidenceSupportError("criteria output is group- or world-writable")


def _published_file_identity(metadata: os.stat_result) -> tuple[int, ...]:
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


def _verify_published_criteria_output(
    directory_descriptor: int,
    filename: str,
    expected_data: bytes,
    staged_identity: tuple[int, ...],
) -> None:
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    verification_descriptor: int | None = None
    reopened_descriptor: int | None = None
    try:
        verification_descriptor = os.open(
            filename,
            flags,
            dir_fd=directory_descriptor,
        )
        before = os.fstat(verification_descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise EvidenceSupportError("published criteria output is not a regular file")
        if before.st_uid != os.geteuid() or before.st_nlink != 1:
            raise EvidenceSupportError(
                "published criteria output has unsafe ownership or link count"
            )
        if stat.S_IMODE(before.st_mode) != CRITERIA_OUTPUT_MODE:
            raise EvidenceSupportError("published criteria output has an unsafe mode")
        if _published_file_identity(before) != staged_identity:
            raise EvidenceSupportError(
                "published criteria output does not name the staged file"
            )

        parts: list[bytes] = []
        total = 0
        while total <= len(expected_data):
            block = os.read(
                verification_descriptor,
                min(64 * 1024, len(expected_data) + 1 - total),
            )
            if not block:
                break
            parts.append(block)
            total += len(block)
        after = os.fstat(verification_descriptor)
        if (
            _published_file_identity(before) != _published_file_identity(after)
            or total != len(expected_data)
            or b"".join(parts) != expected_data
        ):
            raise EvidenceSupportError(
                "published criteria output changed during verification"
            )

        reopened_descriptor = os.open(
            filename,
            flags,
            dir_fd=directory_descriptor,
        )
        reopened = os.fstat(reopened_descriptor)
        if _published_file_identity(reopened) != _published_file_identity(after):
            raise EvidenceSupportError(
                "criteria output pathname changed after publication"
            )
    except OSError as error:
        raise EvidenceSupportError(
            f"published criteria output cannot be verified: {error}"
        ) from error
    finally:
        if reopened_descriptor is not None:
            os.close(reopened_descriptor)
        if verification_descriptor is not None:
            os.close(verification_descriptor)


def write_criteria_output(
    repository: pathlib.Path,
    gate: str,
    data: bytes,
    requested_output: str | None,
) -> pathlib.Path:
    """Atomically publish the one canonical per-gate criteria sidecar."""

    relative = pathlib.PurePosixPath(
        ".forge-codex",
        "state",
        "gate-results",
        f"{gate}.criteria.json",
    )
    output = repository.joinpath(*relative.parts)
    if len(data) > MAXIMUM_CRITERIA_OUTPUT_BYTES:
        raise EvidenceSupportError(
            "criteria output exceeds its "
            f"{MAXIMUM_CRITERIA_OUTPUT_BYTES}-byte bound"
        )
    if requested_output is not None and requested_output != output.as_posix():
        raise EvidenceSupportError(
            "criteria output must be the exact canonical per-gate repository path"
        )

    descriptors: list[int] = []
    identities: list[tuple[int, int, int, int]] = []
    temporary_name: str | None = None
    temporary_descriptor: int | None = None
    try:
        root_descriptor, root_identity = _open_control_directory(
            None,
            repository,
            label="criteria output repository root",
        )
        descriptors.append(root_descriptor)
        identities.append(root_identity)
        parent_descriptor = root_descriptor
        for component, label in (
            (".forge-codex", "criteria output control directory"),
            ("state", "criteria output state directory"),
        ):
            descriptor, identity = _open_control_directory(
                parent_descriptor,
                component,
                label=label,
            )
            descriptors.append(descriptor)
            identities.append(identity)
            parent_descriptor = descriptor

        try:
            results_descriptor, results_identity = _open_control_directory(
                parent_descriptor,
                "gate-results",
                label="criteria output gate-results directory",
            )
        except EvidenceSupportError:
            try:
                os.mkdir("gate-results", mode=0o700, dir_fd=parent_descriptor)
                os.fsync(parent_descriptor)
            except FileExistsError:
                pass
            except OSError as error:
                raise EvidenceSupportError(
                    f"criteria output gate-results directory cannot be created: {error}"
                ) from error
            results_descriptor, results_identity = _open_control_directory(
                parent_descriptor,
                "gate-results",
                label="criteria output gate-results directory",
            )
        descriptors.append(results_descriptor)
        identities.append(results_identity)

        filename = relative.name
        _validate_existing_criteria_output(results_descriptor, filename)
        creation_flags = (
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        for _ in range(16):
            candidate = f".{filename}.{uuid.uuid4().hex}.tmp"
            try:
                temporary_descriptor = os.open(
                    candidate,
                    creation_flags,
                    CRITERIA_OUTPUT_MODE,
                    dir_fd=results_descriptor,
                )
            except FileExistsError:
                continue
            temporary_name = candidate
            break
        if temporary_descriptor is None or temporary_name is None:
            raise EvidenceSupportError("criteria output temporary name space is exhausted")

        offset = 0
        while offset < len(data):
            written = os.write(temporary_descriptor, data[offset:])
            if written <= 0:
                raise EvidenceSupportError("criteria output staging write made no progress")
            offset += written
        os.fchmod(temporary_descriptor, CRITERIA_OUTPUT_MODE)
        os.fsync(temporary_descriptor)
        staged = os.fstat(temporary_descriptor)
        if (
            not stat.S_ISREG(staged.st_mode)
            or staged.st_uid != os.geteuid()
            or staged.st_nlink != 1
            or stat.S_IMODE(staged.st_mode) != CRITERIA_OUTPUT_MODE
            or staged.st_size != len(data)
        ):
            raise EvidenceSupportError("criteria output staging file is unsafe")

        os.replace(
            temporary_name,
            filename,
            src_dir_fd=results_descriptor,
            dst_dir_fd=results_descriptor,
        )
        temporary_name = None
        os.fsync(results_descriptor)
        staged_identity = _published_file_identity(os.fstat(temporary_descriptor))
        _verify_published_criteria_output(
            results_descriptor,
            filename,
            data,
            staged_identity,
        )

        reopened_descriptors: list[int] = []
        try:
            reopened_root, reopened_identity = _open_control_directory(
                None,
                repository,
                label="criteria output repository root",
            )
            reopened_descriptors.append(reopened_root)
            reopened_identities = [reopened_identity]
            reopened_parent = reopened_root
            for component, label in (
                (".forge-codex", "criteria output control directory"),
                ("state", "criteria output state directory"),
                ("gate-results", "criteria output gate-results directory"),
            ):
                descriptor, identity = _open_control_directory(
                    reopened_parent,
                    component,
                    label=label,
                )
                reopened_descriptors.append(descriptor)
                reopened_identities.append(identity)
                reopened_parent = descriptor
            if reopened_identities != identities:
                raise EvidenceSupportError(
                    "criteria output directory path changed during publication"
                )
        finally:
            for descriptor in reversed(reopened_descriptors):
                os.close(descriptor)
    except OSError as error:
        raise EvidenceSupportError(f"criteria output cannot be published: {error}") from error
    finally:
        if temporary_descriptor is not None:
            os.close(temporary_descriptor)
        if temporary_name is not None and descriptors:
            try:
                os.unlink(temporary_name, dir_fd=descriptors[-1])
            except OSError:
                pass
        for descriptor in reversed(descriptors):
            os.close(descriptor)
    return output


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("gate")
    parser.add_argument("--repo")
    parser.add_argument("--acceptance")
    parser.add_argument("--criteria-output")
    parser.add_argument("--p10-feature-binding")
    return parser


def main(arguments: list[str] | None = None) -> int:
    args = build_parser().parse_args(arguments)
    if not isinstance(args.gate, str) or re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}",
        args.gate,
    ) is None:
        raise SystemExit("invalid gate identifier")
    repository = locate_repo(args.repo)
    control_budget = BoundedReadBudget(
        MAXIMUM_CONTROL_JSON_TOTAL_BYTES,
        "acceptance control JSON",
    )
    try:
        plan = load_bounded_repository_json_object(
            repository,
            ".forge-codex/plans/gates.json",
            label="gate plan",
            maximum_bytes=MAXIMUM_CONTROL_JSON_FILE_BYTES,
            budget=control_budget,
        )
    except EvidenceSupportError as error:
        raise SystemExit(str(error)) from error

    gates = plan.get("gates")
    gate = (
        next(
            (
                candidate
                for candidate in gates
                if isinstance(candidate, dict) and candidate.get("id") == args.gate
            ),
            None,
        )
        if isinstance(gates, list)
        else None
    )
    if gate is None:
        raise SystemExit("unknown gate")
    criteria = gate.get("criteria")
    if (
        not isinstance(criteria, list)
        or not criteria
        or not all(isinstance(criterion, str) and criterion for criterion in criteria)
        or len(set(criteria)) != len(criteria)
    ):
        raise SystemExit("gate criteria are malformed")

    try:
        if args.acceptance:
            acceptance_relative, acceptance = canonical_repository_path(
                repository,
                args.acceptance,
                base=pathlib.Path.cwd().resolve(),
                label="acceptance record",
            )
        else:
            acceptance_relative = (
                pathlib.PurePosixPath(".forge-codex")
                / "state"
                / "acceptance"
                / f"{args.gate}.json"
            ).as_posix()
            acceptance = repository.joinpath(
                *pathlib.PurePosixPath(acceptance_relative).parts
            )
    except EvidenceSupportError as error:
        raise SystemExit(str(error)) from error

    if path_is_missing(acceptance):
        print(f"acceptance record missing: {acceptance}", file=sys.stderr)
        return 1
    try:
        record = load_bounded_repository_json_object(
            repository,
            acceptance_relative,
            label="acceptance record",
            maximum_bytes=MAXIMUM_CONTROL_JSON_FILE_BYTES,
            budget=control_budget,
        )
    except EvidenceSupportError as error:
        raise SystemExit(str(error)) from error

    errors: list[str] = []
    p10_feature_binding: dict[str, Any] | None = None
    if args.p10_feature_binding is not None:
        canonical_binding = (
            repository
            / ".forge-codex/state/gate-results/G10.p10-feature-binding.json"
        )
        if args.gate != "G10" or args.p10_feature_binding != str(canonical_binding):
            errors.append("P10 feature binding path or gate is not canonical")
        else:
            try:
                p10_feature_binding = load_bounded_repository_json_object(
                    repository,
                    ".forge-codex/state/gate-results/G10.p10-feature-binding.json",
                    label="P10 feature binding",
                    maximum_bytes=MAXIMUM_CONTROL_JSON_FILE_BYTES,
                    budget=control_budget,
                )
                run_state = load_bounded_repository_json_object(
                    repository,
                    ".forge-codex/state/run-state.json",
                    label="P10 feature binding run state",
                    maximum_bytes=MAXIMUM_CONTROL_JSON_FILE_BYTES,
                    budget=control_budget,
                )
                head = current_git_head(repository)
                if head is None:
                    errors.append("P10 feature binding Git HEAD is unavailable")
                else:
                    errors.extend(
                        validate_p10_feature_binding(
                            repository,
                            p10_feature_binding,
                            current_manifest=source_manifest(repository),
                            current_git_head=head,
                            ledger_evidence_ids={
                                item
                                for item in run_state.get("evidence", [])
                                if isinstance(item, str)
                            },
                        )
                    )
            except EvidenceSupportError as error:
                errors.append(str(error))
    if record.get("gate_id") != args.gate:
        errors.append(
            f"acceptance record gate_id must be exactly {args.gate}"
        )
    if record.get("current_release_authority") is not True:
        scope = record.get("authority_scope", "historical")
        revision = record.get("qualified_source_revision", "unknown")
        errors.append(
            f"acceptance record is {scope} evidence for {revision}, "
            "not current release authority"
        )

    criteria_results = record.get("criteria_results", [])
    criteria_by_text: dict[Any, dict[str, Any]] = {}
    if isinstance(criteria_results, list):
        for candidate in criteria_results:
            if isinstance(candidate, dict):
                criterion = candidate.get("criterion")
                try:
                    if criterion in criteria_by_text:
                        errors.append(f"duplicate criterion record: {criterion}")
                    criteria_by_text[criterion] = candidate
                except TypeError:
                    errors.append("malformed criterion record")
            else:
                errors.append("malformed criterion record")
    else:
        errors.append("malformed criterion record")
    for criterion in criteria_by_text:
        if criterion not in criteria:
            errors.append(f"unexpected criterion: {criterion}")

    require_repository_evidence = args.gate == "G10"
    evidence_budget = BoundedReadBudget(
        (
            MAXIMUM_G10_EVIDENCE_TOTAL_BYTES
            if require_repository_evidence
            else MAXIMUM_EVIDENCE_TOTAL_BYTES
        ),
        "acceptance evidence",
    )
    normalized: list[dict[str, Any]] = []
    for criterion in criteria:
        item = criteria_by_text.get(criterion)
        if item is None:
            errors.append(f"missing criterion: {criterion}")
            normalized.append({
                "criterion": criterion,
                "passed": False,
                "evidence": "missing",
            })
            continue

        evidence = item.get("evidence", [])
        criterion_error_count = len(errors)
        if not isinstance(evidence, list) or not evidence:
            errors.append(f"criterion has no evidence artifacts: {criterion}")
        artifact_notes: list[str] = []
        for artifact in evidence if isinstance(evidence, list) else []:
            if (
                not isinstance(artifact, dict)
                or "path" not in artifact
                or "sha256" not in artifact
                or not isinstance(artifact.get("sha256"), str)
                or re.fullmatch(r"[0-9a-f]{64}", artifact["sha256"]) is None
            ):
                errors.append(f"malformed evidence for: {criterion}")
                continue
            try:
                path, actual = stable_evidence_digest(
                    repository,
                    artifact["path"],
                    label=f"criterion evidence for {criterion}",
                    budget=evidence_budget,
                    require_repository_content=require_repository_evidence,
                )
            except EvidenceSupportError as error:
                raw_path = artifact.get("path")
                try:
                    _, path = canonical_repository_path(
                        repository,
                        raw_path,
                        base=repository,
                        label=f"criterion evidence for {criterion}",
                    )
                except EvidenceSupportError:
                    if require_repository_evidence:
                        errors.append(f"malformed evidence for: {criterion}")
                        continue
                    try:
                        path = canonical_external_path(
                            raw_path,
                            label=f"criterion evidence for {criterion}",
                        )
                    except EvidenceSupportError:
                        errors.append(f"malformed evidence for: {criterion}")
                        continue
                    if path_is_missing(path):
                        errors.append(f"missing artifact: {path}")
                    else:
                        errors.append(f"invalid artifact: {path}: {error}")
                else:
                    if path_is_missing(path):
                        errors.append(f"missing artifact: {path}")
                    else:
                        errors.append(f"invalid artifact: {path}: {error}")
                continue
            if actual != artifact["sha256"]:
                errors.append(
                    f"malformed evidence for: {criterion}: hash mismatch: {path}"
                )
            artifact_notes.append(f"{path}#{actual}")

        passed = (
            item.get("passed") is True
            and bool(evidence)
            and len(errors) == criterion_error_count
        )
        normalized.append({
            "criterion": criterion,
            "passed": passed,
            "evidence": "; ".join(artifact_notes) or "invalid",
        })
        if item.get("passed") is not True:
            errors.append(f"criterion marked failed: {criterion}")

    commands = record.get("commands", [])
    if not isinstance(commands, list) or not commands:
        errors.append("acceptance record has no commands")
    for command in commands if isinstance(commands, list) else []:
        if (
            not isinstance(command, dict)
            or not {"command", "exit_code", "evidence"}.issubset(command)
            or not isinstance(command.get("command"), str)
            or not command["command"]
            or not isinstance(command.get("exit_code"), int)
            or isinstance(command.get("exit_code"), bool)
        ):
            errors.append("malformed command record")
            continue
        try:
            path, _ = stable_evidence_digest(
                repository,
                command["evidence"],
                label="command evidence",
                budget=evidence_budget,
                require_repository_content=require_repository_evidence,
            )
        except EvidenceSupportError as error:
            try:
                _, path = canonical_repository_path(
                    repository,
                    command.get("evidence"),
                    base=repository,
                    label="command evidence",
                )
            except EvidenceSupportError:
                if require_repository_evidence:
                    errors.append("malformed command record")
                    continue
                try:
                    path = canonical_external_path(
                        command.get("evidence"),
                        label="command evidence",
                    )
                except EvidenceSupportError:
                    errors.append("malformed command record")
                    continue
                if path_is_missing(path):
                    errors.append(f"command evidence missing: {path}")
                else:
                    errors.append(f"command evidence invalid: {path}: {error}")
            else:
                if path_is_missing(path):
                    errors.append(f"command evidence missing: {path}")
                else:
                    errors.append(f"command evidence invalid: {path}: {error}")
        if command["exit_code"] != 0:
            errors.append(f"command failed: {command['command']}")

    payload = {
        "criteria_results": normalized,
        "valid": not errors,
        "errors": errors,
    }
    if p10_feature_binding is not None:
        payload["p10_feature_binding"] = p10_feature_binding
    encoded_payload = (
        json.dumps(payload, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")
    try:
        write_criteria_output(
            repository,
            args.gate,
            encoded_payload,
            args.criteria_output,
        )
    except EvidenceSupportError as error:
        raise SystemExit(str(error)) from error
    print(json.dumps(payload, indent=2))
    return 0 if not errors and all(item["passed"] for item in normalized) else 1


if __name__ == "__main__":
    raise SystemExit(main())
