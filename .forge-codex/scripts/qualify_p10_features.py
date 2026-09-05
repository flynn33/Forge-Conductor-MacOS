#!/usr/bin/env python3
"""Execute the canonical P10 production-probe matrix under bounded capture.

The production probe registry is intentionally fail-closed: an assertion is not
qualified until its exact runner has been reviewed into the pinned registry.
"""

from __future__ import annotations

import argparse
import base64
import binascii
from datetime import datetime, timezone
import hashlib
import json
import os
import pathlib
import platform
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any
import urllib.error
import urllib.parse
import urllib.request

from evidence_support import (
    BoundedReadBudget,
    EvidenceSupportError,
    atomic_write_json,
    current_git_head,
    decode_strict_json_object,
    read_bounded_repository_bytes,
    source_manifest,
)
from record_command import execute_command
import p10_native_cli_scenario as native_cli
from p10_feature_baseline import (
    EXPECTED_QUALIFIER,
    FEATURE_BASELINE_PATH,
    FEATURE_REGISTRY_PATH,
    signing_artifact_from_assertion,
)


PROBE_REGISTRY_PATH = ".forge-codex/specifications/p10-production-probes.v1.json"
REPORT_PATH = ".forge-codex/evidence/P10-feature-production-qualification-report.json"
CANONICAL_FEATURE_REGISTRY_ID = "forge-conductor-p10-feature-registry"
MAXIMUM_CONTROL_BYTES = 1024 * 1024
MAXIMUM_STREAM_BYTES_PER_PROBE = 64 * 1024
MAXIMUM_PROBE_SECONDS = 900
MAXIMUM_MATRIX_SECONDS = 1500
MAXIMUM_TOTAL_RAW_OUTPUT_BYTES = 8 * 1024 * 1024
MAXIMUM_UNIQUE_RUNNERS = 64
MAXIMUM_INSTALLED_ARTIFACT_BYTES = 512 * 1024 * 1024
MAXIMUM_CLI_ARGUMENTS = 64
MAXIMUM_CLI_ARGUMENT_BYTES = 4096
MAXIMUM_CLI_TIMEOUT_SECONDS = 120
MAXIMUM_CLI_STREAM_BYTES = 64 * 1024
MAXIMUM_OBSERVATION_BYTES_PER_SCENARIO = 256 * 1024
OBSERVATION_PATH = ".forge-codex/evidence/P10-feature-production-observations.json"
CDHASH = re.compile(r"[0-9a-f]{40}")


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")


def probe_environment() -> dict[str, str]:
    environment = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "C",
        "LC_ALL": "C",
        "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
    }
    for key in ("HOME", "TMPDIR"):
        value = os.environ.get(key)
        if isinstance(value, str) and value.startswith("/"):
            environment[key] = value
    return environment


def bounded_remaining_seconds(deadline: float, requested: int, *, now_value: float | None = None) -> int:
    remaining = int(deadline - (time.monotonic() if now_value is None else now_value))
    if remaining < 1:
        raise EvidenceSupportError("P10 production probe matrix exceeded its total deadline")
    return min(requested, remaining)


def load_json(repository: pathlib.Path, relative: str, label: str) -> tuple[dict[str, Any], bytes]:
    raw = read_bounded_repository_bytes(
        repository,
        relative,
        label=label,
        maximum_bytes=MAXIMUM_CONTROL_BYTES,
        budget=BoundedReadBudget(MAXIMUM_CONTROL_BYTES, label),
    )
    return decode_strict_json_object(raw, label=label), raw


def runner_argv(repository: pathlib.Path, probe: dict[str, Any]) -> tuple[list[str], int]:
    probe_label = probe.get("scenario_id", probe.get("probe_id"))
    runner = probe.get("runner")
    if not isinstance(runner, dict):
        raise EvidenceSupportError(f"probe {probe_label} has no concrete runner")
    kind = runner.get("kind")
    timeout = runner.get("timeout_seconds")
    if type(timeout) is not int or not (1 <= timeout <= MAXIMUM_PROBE_SECONDS):
        raise EvidenceSupportError(f"probe {probe_label} has an invalid timeout")
    if kind == native_cli.RUNNER_KIND:
        if not (native_cli.scenario_valid(probe) or native_cli.scenario_valid(probe, allow_bound_root=True)):
            raise EvidenceSupportError("native CLI scenario differs from the reviewed contract")
        return [probe["installation"]["root"] + "/Contents/Helpers/forge-conductor"], timeout
    if kind == "repository_qualification":
        expected_keys = {"kind", "executable", "arguments", "timeout_seconds"}
        if set(runner) != expected_keys:
            raise EvidenceSupportError(f"probe {probe_label} repository runner is malformed")
        executable = runner.get("executable")
        arguments = runner.get("arguments")
        if (
            not isinstance(executable, str)
            or not executable.startswith(".forge-codex/scripts/qualification-probes/")
            or pathlib.PurePosixPath(executable).as_posix() != executable
            or ".." in pathlib.PurePosixPath(executable).parts
            or not isinstance(arguments, list)
            or len(arguments) > 64
            or any(not isinstance(item, str) or not item or len(item.encode("utf-8")) > 4096 for item in arguments)
        ):
            raise EvidenceSupportError(f"probe {probe_label} repository runner is invalid")
        executable_path = repository / executable
        try:
            resolved_executable = executable_path.resolve(strict=True)
        except OSError as error:
            raise EvidenceSupportError(f"probe {probe_label} repository runner is unavailable: {error}") from error
        if resolved_executable != executable_path or not executable_path.is_file() or executable_path.is_symlink():
            raise EvidenceSupportError(f"probe {probe_label} repository runner is unavailable")
        return [str(executable_path), *arguments], timeout
    raise EvidenceSupportError(f"probe {probe_label} runner kind is not allowlisted")


def runner_identity(probe: dict[str, Any]) -> str:
    """Identify executed work without treating its deadline as semantic diversity."""

    runner = probe.get("runner")
    if not isinstance(runner, dict):
        return ""
    identity = {key: value for key, value in runner.items() if key != "timeout_seconds"}
    return hashlib.sha256(canonical_bytes(identity)).hexdigest()


def installation_contract_valid(value: Any) -> bool:
    if not isinstance(value, dict) or set(value) != {
        "root", "configuration", "process_artifact_id", "artifacts",
    }:
        return False
    root = value.get("root")
    artifacts = value.get("artifacts")
    if (
        not isinstance(root, str)
        or not root.startswith("/")
        or value.get("configuration") != "Release"
        or not isinstance(value.get("process_artifact_id"), str)
        or not isinstance(artifacts, list)
        or not (1 <= len(artifacts) <= 8)
    ):
        return False
    identifiers: list[str] = []
    for artifact in artifacts:
        if not isinstance(artifact, dict) or set(artifact) != {
            "artifact_id", "relative_path", "kind",
        }:
            return False
        artifact_id = artifact.get("artifact_id")
        relative = artifact.get("relative_path")
        if (
            not isinstance(artifact_id, str)
            or not artifact_id
            or not isinstance(relative, str)
            or pathlib.PurePosixPath(relative).as_posix() != relative
            or pathlib.PurePosixPath(relative).is_absolute()
            or ".." in pathlib.PurePosixPath(relative).parts
            or artifact.get("kind") not in {"executable", "app-executable", "helper"}
        ):
            return False
        identifiers.append(artifact_id)
    return (
        len(identifiers) == len(set(identifiers))
        and value["process_artifact_id"] in identifiers
    )


def installed_cli_contract_valid(value: Any) -> bool:
    if not isinstance(value, dict) or set(value) != {
        "artifact_id", "argv", "cwd", "timeout_seconds", "expected_exit_code",
        "stdout", "stderr",
    }:
        return False
    argv = value.get("argv")
    cwd = value.get("cwd")
    if (
        value.get("artifact_id") != "forge-conductor-cli"
        or not isinstance(argv, list)
        or len(argv) > MAXIMUM_CLI_ARGUMENTS
        or any(
            not isinstance(item, str)
            or "\0" in item
            or len(item.encode("utf-8")) > MAXIMUM_CLI_ARGUMENT_BYTES
            for item in argv
        )
        or not isinstance(cwd, str)
        or not cwd.startswith("/")
        or "\0" in cwd
        or len(cwd.encode("utf-8")) > 4096
        or type(value.get("timeout_seconds")) is not int
        or not (1 <= value["timeout_seconds"] <= MAXIMUM_CLI_TIMEOUT_SECONDS)
        or type(value.get("expected_exit_code")) is not int
        or not (-255 <= value["expected_exit_code"] <= 255)
    ):
        return False
    for stream_name in ("stdout", "stderr"):
        stream = value.get(stream_name)
        if not isinstance(stream, dict) or set(stream) != {
            "encoding", "exact", "maximum_bytes",
        }:
            return False
        exact = stream.get("exact")
        maximum = stream.get("maximum_bytes")
        if (
            stream.get("encoding") != "utf-8"
            or not isinstance(exact, str)
            or type(maximum) is not int
            or not (0 <= maximum <= MAXIMUM_CLI_STREAM_BYTES)
            or len(exact.encode("utf-8")) > maximum
        ):
            return False
    return True


def _stable_file_binding(path: pathlib.Path, *, artifact_id: str, kind: str) -> dict[str, Any]:
    before = path.lstat()
    if path.is_symlink() or not stat.S_ISREG(before.st_mode) or before.st_size < 1:
        raise EvidenceSupportError(f"installed artifact {artifact_id} is not one exact regular file")
    if before.st_size > MAXIMUM_INSTALLED_ARTIFACT_BYTES:
        raise EvidenceSupportError(f"installed artifact {artifact_id} exceeds its byte bound")
    digest = hashlib.sha256()
    total = 0
    with path.open("rb") as stream:
        while True:
            chunk = stream.read(1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            digest.update(chunk)
    after = path.lstat()
    identity = lambda value: (
        value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
        value.st_size, value.st_mtime_ns, value.st_ctime_ns,
    )
    if identity(before) != identity(after) or total != before.st_size:
        raise EvidenceSupportError(f"installed artifact {artifact_id} changed during hashing")
    return {
        "artifact_id": artifact_id,
        "kind": kind,
        "path": str(path),
        "sha256": digest.hexdigest(),
        "bytes": total,
    }


def derive_installation_facts(
    probe: dict[str, Any],
    observation: dict[str, Any],
    *,
    require_live_process: bool,
) -> dict[str, Any]:
    if probe.get("runner", {}).get("kind") == native_cli.RUNNER_KIND:
        probe = native_cli.probe_from_observation(probe, observation)
    contract = probe.get("installation")
    if not installation_contract_valid(contract):
        raise EvidenceSupportError("P10 production scenario has no exact installation contract")
    root = pathlib.Path(contract["root"])
    resolved_root = root.resolve(strict=True)
    if root != resolved_root or not resolved_root.is_dir() or root.is_symlink():
        raise EvidenceSupportError("P10 installation root is not canonical")
    bindings: list[dict[str, Any]] = []
    by_id: dict[str, dict[str, Any]] = {}
    for declared in contract["artifacts"]:
        path = root / declared["relative_path"]
        resolved = path.resolve(strict=True)
        if resolved != path or resolved_root not in resolved.parents:
            raise EvidenceSupportError("P10 installed artifact escapes its canonical root")
        item = _stable_file_binding(
            resolved,
            artifact_id=declared["artifact_id"],
            kind=declared["kind"],
        )
        bindings.append(item)
        by_id[item["artifact_id"]] = item
    process = observation.get("process")
    if not isinstance(process, dict) or set(process) != {"pid", "artifact_id", "executable_path"}:
        raise EvidenceSupportError("P10 observation has no exact process identity")
    pid = process.get("pid")
    process_artifact = by_id.get(process.get("artifact_id"))
    if (
        type(pid) is not int
        or pid <= 1
        or process.get("artifact_id") != contract["process_artifact_id"]
        or process_artifact is None
        or process.get("executable_path") != process_artifact["path"]
    ):
        raise EvidenceSupportError("P10 observation process is not bound to the installed bytes")
    if require_live_process:
        result = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "comm="],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        observed_path = result.stdout.decode("utf-8", errors="strict").strip()
        try:
            observed_resolved = pathlib.Path(observed_path).resolve(strict=True)
        except OSError as error:
            raise EvidenceSupportError(f"P10 observed process path is unavailable: {error}") from error
        if result.returncode != 0 or observed_resolved != pathlib.Path(process_artifact["path"]):
            raise EvidenceSupportError("P10 installed process identity is not live and exact")
    bindings.sort(key=lambda item: item["artifact_id"])
    coherent_build_sha256 = hashlib.sha256(canonical_bytes(bindings)).hexdigest()
    return {
        "root": str(root),
        "configuration": "Release",
        "process": {**process, "executable_sha256": process_artifact["sha256"]},
        "artifacts": bindings,
        "coherent_build_sha256": coherent_build_sha256,
    }


def _parse_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > 128:
        return None
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None and parsed.utcoffset() is not None else None


def _installed_cli_artifact(installation: dict[str, Any]) -> dict[str, Any]:
    artifact = next(
        (
            item for item in installation.get("artifacts", [])
            if isinstance(item, dict) and item.get("artifact_id") == "forge-conductor-cli"
        ),
        None,
    )
    if not isinstance(artifact, dict) or set(artifact) != {
        "artifact_id", "kind", "path", "sha256", "bytes",
    }:
        raise EvidenceSupportError("P10 CLI assertion has no exact installed CLI artifact")
    path = pathlib.Path(artifact["path"])
    current = _stable_file_binding(
        path.resolve(strict=True),
        artifact_id="forge-conductor-cli",
        kind=artifact["kind"],
    )
    if current != artifact:
        raise EvidenceSupportError("P10 installed CLI bytes changed before observation")
    return artifact


def _copy_verified_executable_snapshot(
    source: pathlib.Path,
    destination: pathlib.Path,
    expected: dict[str, Any],
) -> dict[str, Any]:
    """Copy one receipted executable through a stable open descriptor."""

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
    digest = hashlib.sha256()
    total = 0
    identity = lambda value: (
        value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
        value.st_size, value.st_mtime_ns, value.st_ctime_ns,
    )
    try:
        before = os.fstat(source_descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_size != expected.get("bytes")
            or before.st_size < 1
            or before.st_size > MAXIMUM_INSTALLED_ARTIFACT_BYTES
        ):
            raise EvidenceSupportError("P10 installed CLI descriptor is not the receipted regular file")
        destination_descriptor = os.open(destination, destination_flags, 0o500)
        while True:
            block = os.read(source_descriptor, 1024 * 1024)
            if not block:
                break
            total += len(block)
            digest.update(block)
            view = memoryview(block)
            while view:
                written = os.write(destination_descriptor, view)
                if written < 1:
                    raise EvidenceSupportError("P10 installed CLI snapshot write made no progress")
                view = view[written:]
        after = os.fstat(source_descriptor)
        os.fsync(destination_descriptor)
        os.fchmod(destination_descriptor, 0o500)
    finally:
        if destination_descriptor is not None:
            os.close(destination_descriptor)
        os.close(source_descriptor)
    snapshot = {"sha256": digest.hexdigest(), "bytes": total}
    if (
        identity(before) != identity(after)
        or snapshot != {"sha256": expected.get("sha256"), "bytes": expected.get("bytes")}
    ):
        raise EvidenceSupportError("P10 installed CLI bytes changed while creating its execution snapshot")
    return snapshot


def capture_installed_cli_transcript(
    binding: dict[str, Any],
    installation: dict[str, Any],
    *,
    challenge_nonce: str,
    matrix_deadline: float,
) -> dict[str, Any]:
    """Capture a synthetic-only, verified snapshot of exact installed CLI bytes."""

    contract = binding.get("expected")
    selector = binding.get("selector")
    if (
        binding.get("evidence_kind") != "installed-cli-transcript"
        or not isinstance(selector, str)
        or not installed_cli_contract_valid(contract)
    ):
        raise EvidenceSupportError("P10 installed CLI assertion contract is malformed")
    artifact = _installed_cli_artifact(installation)
    executable = pathlib.Path(artifact["path"])
    cwd = pathlib.Path(contract["cwd"])
    resolved_cwd = cwd.resolve(strict=True)
    if cwd != resolved_cwd or cwd.is_symlink() or not cwd.is_dir():
        raise EvidenceSupportError("P10 installed CLI working directory is not canonical")
    timeout = bounded_remaining_seconds(matrix_deadline, contract["timeout_seconds"])
    capture_limit = max(
        contract["stdout"]["maximum_bytes"],
        contract["stderr"]["maximum_bytes"],
    )
    started_at = now()
    with tempfile.TemporaryDirectory(prefix="forge-p10-cli-") as temporary:
        temporary_root = pathlib.Path(temporary)
        execution_snapshot_path = temporary_root / "installed-cli-execution-snapshot"
        execution_snapshot = _copy_verified_executable_snapshot(
            executable,
            execution_snapshot_path,
            artifact,
        )
        stdout_path = temporary_root / "stdout"
        stderr_path = temporary_root / "stderr"
        exit_code, timed_out, stream_limit_exceeded = execute_command(
            [str(execution_snapshot_path), *contract["argv"]],
            resolved_cwd,
            stdout_path,
            stderr_path,
            timeout,
            capture_limit,
            probe_environment(),
        )
        stdout = stdout_path.read_bytes()
        stderr = stderr_path.read_bytes()
    ended_at = now()
    if _installed_cli_artifact(installation) != artifact:
        raise EvidenceSupportError("P10 installed CLI bytes changed during observation")
    stream_document = lambda raw: {
        "base64": base64.b64encode(raw).decode("ascii"),
        "sha256": hashlib.sha256(raw).hexdigest(),
        "bytes": len(raw),
    }
    return {
        "selector": selector,
        "evidence_kind": "installed-cli-transcript",
        "request": {
            "challenge_nonce": challenge_nonce,
            "selector": selector,
            "artifact_id": contract["artifact_id"],
            "argv": contract["argv"],
            "cwd": contract["cwd"],
            "timeout_seconds": contract["timeout_seconds"],
        },
        "response": {
            "challenge_nonce": challenge_nonce,
            "selector": selector,
            "artifact": {
                "artifact_id": artifact["artifact_id"],
                "path": artifact["path"],
                "sha256": artifact["sha256"],
                "bytes": artifact["bytes"],
            },
            "execution_snapshot": execution_snapshot,
            "argv": contract["argv"],
            "cwd": contract["cwd"],
            "started_at": started_at,
            "ended_at": ended_at,
            "exit_code": exit_code,
            "timed_out": timed_out,
            "stream_limit_exceeded": stream_limit_exceeded,
            "stdout": stream_document(stdout),
            "stderr": stream_document(stderr),
        },
    }


def validate_installed_cli_transcript(
    binding: dict[str, Any],
    result: Any,
    installation: dict[str, Any],
    *,
    challenge_nonce: str,
) -> bool:
    contract = binding.get("expected")
    selector = binding.get("selector")
    if (
        not installed_cli_contract_valid(contract)
        or not isinstance(selector, str)
        or not isinstance(result, dict)
        or set(result) != {"selector", "evidence_kind", "request", "response"}
        or result.get("selector") != selector
        or result.get("evidence_kind") != "installed-cli-transcript"
        or result.get("request") != {
            "challenge_nonce": challenge_nonce,
            "selector": selector,
            "artifact_id": contract.get("artifact_id"),
            "argv": contract.get("argv"),
            "cwd": contract.get("cwd"),
            "timeout_seconds": contract.get("timeout_seconds"),
        }
    ):
        return False
    response = result.get("response")
    if not isinstance(response, dict) or set(response) != {
        "challenge_nonce", "selector", "artifact", "execution_snapshot", "argv", "cwd",
        "started_at", "ended_at",
        "exit_code", "timed_out", "stream_limit_exceeded", "stdout", "stderr",
    }:
        return False
    try:
        artifact = _installed_cli_artifact(installation)
        cwd = pathlib.Path(contract["cwd"])
        if cwd.resolve(strict=True) != cwd or cwd.is_symlink() or not cwd.is_dir():
            return False
    except (OSError, EvidenceSupportError, KeyError, TypeError):
        return False
    expected_artifact = {
        "artifact_id": artifact["artifact_id"],
        "path": artifact["path"],
        "sha256": artifact["sha256"],
        "bytes": artifact["bytes"],
    }
    started = _parse_timestamp(response.get("started_at"))
    ended = _parse_timestamp(response.get("ended_at"))
    if (
        response.get("challenge_nonce") != challenge_nonce
        or response.get("selector") != selector
        or response.get("artifact") != expected_artifact
        or response.get("execution_snapshot") != {
            "sha256": artifact["sha256"],
            "bytes": artifact["bytes"],
        }
        or response.get("argv") != contract["argv"]
        or response.get("cwd") != contract["cwd"]
        or started is None
        or ended is None
        or started > ended
        or (ended - started).total_seconds() > contract["timeout_seconds"] + 1
        or type(response.get("exit_code")) is not int
        or response.get("exit_code") != contract["expected_exit_code"]
        or response.get("timed_out") is not False
        or response.get("stream_limit_exceeded") is not False
    ):
        return False
    for stream_name in ("stdout", "stderr"):
        stream = response.get(stream_name)
        expected_stream = contract[stream_name]
        if not isinstance(stream, dict) or set(stream) != {"base64", "sha256", "bytes"}:
            return False
        try:
            raw = base64.b64decode(stream.get("base64", ""), validate=True)
            text = raw.decode("utf-8", errors="strict")
        except (binascii.Error, UnicodeDecodeError, ValueError):
            return False
        if (
            base64.b64encode(raw).decode("ascii") != stream.get("base64")
            or stream.get("bytes") != len(raw)
            or stream.get("sha256") != hashlib.sha256(raw).hexdigest()
            or len(raw) > expected_stream["maximum_bytes"]
            or text != expected_stream["exact"]
        ):
            return False
    return True


def derive_signing_fact(
    binding: dict[str, Any],
    installation: dict[str, Any],
) -> dict[str, Any]:
    expected = binding.get("expected")
    if not isinstance(expected, dict) or set(expected) != {
        "artifact_id", "team_id", "identifier", "hardened_runtime",
    }:
        raise EvidenceSupportError("P10 signing assertion has no exact expected identity")
    artifact = next(
        (item for item in installation.get("artifacts", []) if item.get("artifact_id") == expected["artifact_id"]),
        None,
    )
    if not isinstance(artifact, dict):
        raise EvidenceSupportError("P10 signing assertion does not name installed bytes")
    display = subprocess.run(
        ["/usr/bin/codesign", "-dvvv", artifact["path"]],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
        check=False,
    )
    details = (display.stdout + display.stderr).decode("utf-8", errors="strict")
    fields: dict[str, str] = {}
    for line in details.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            fields[key.strip()] = value.strip()
    # codesign places flags on the CodeDirectory line, not a separate key.
    flags = re.search(r"\bflags=(0x[0-9a-fA-F]+)", details)
    hardened_runtime = flags is not None and bool(int(flags.group(1), 16) & 0x10000)
    if (
        display.returncode != 0
        or fields.get("TeamIdentifier") != expected.get("team_id")
        or fields.get("Identifier") != expected.get("identifier")
        or hardened_runtime is not expected.get("hardened_runtime")
        or CDHASH.fullmatch(fields.get("CDHash", "")) is None
    ):
        raise EvidenceSupportError("P10 codesign identity does not match the reviewed contract")
    requirement = subprocess.run(
        ["/usr/bin/codesign", "-d", "-r-", artifact["path"]],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
        check=False,
    )
    requirement_bytes = requirement.stdout + requirement.stderr
    if requirement.returncode != 0 or b"designated =>" not in requirement_bytes:
        raise EvidenceSupportError("P10 designated requirement is unavailable")
    return {
        "applicable": True,
        "artifact_id": artifact["artifact_id"],
        "path": artifact["path"],
        "artifact_sha256": artifact["sha256"],
        "artifact_bytes": artifact["bytes"],
        "team_id": fields["TeamIdentifier"],
        "identifier": fields["Identifier"],
        "cdhash": fields["CDHash"],
        "designated_requirement_sha256": hashlib.sha256(requirement_bytes).hexdigest(),
        "hardened_runtime": hardened_runtime,
    }


def derive_provider_fact(
    binding: dict[str, Any],
    observation: dict[str, Any],
    *,
    challenge_nonce: str,
) -> dict[str, Any]:
    expected = binding.get("expected")
    if not isinstance(expected, dict) or set(expected) != {"endpoint", "model", "timeout_seconds"}:
        raise EvidenceSupportError("P10 provider assertion has no exact endpoint and model contract")
    endpoint = expected.get("endpoint")
    model = expected.get("model")
    timeout = expected.get("timeout_seconds")
    parsed = urllib.parse.urlsplit(endpoint) if isinstance(endpoint, str) else None
    if (
        parsed is None
        or parsed.scheme != "http"
        or parsed.hostname not in {"127.0.0.1", "::1", "localhost"}
        or parsed.port is None
        or parsed.path != "/v1/chat/completions"
        or parsed.query
        or parsed.fragment
        or not isinstance(model, str)
        or not model
        or type(timeout) is not int
        or not (1 <= timeout <= 60)
    ):
        raise EvidenceSupportError("P10 provider endpoint is not an exact bounded loopback chat endpoint")
    provider_process = observation.get("provider_process")
    if not isinstance(provider_process, dict) or set(provider_process) != {"pid", "executable_path"}:
        raise EvidenceSupportError("P10 provider observation has no process identity")
    pid = provider_process.get("pid")
    executable_path = provider_process.get("executable_path")
    if type(pid) is not int or pid <= 1 or not isinstance(executable_path, str):
        raise EvidenceSupportError("P10 provider process identity is malformed")
    process = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "comm="],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=5,
        check=False,
    )
    observed_process = process.stdout.decode("utf-8", errors="strict").strip()
    if (
        process.returncode != 0
        or pathlib.Path(observed_process).resolve(strict=True) != pathlib.Path(executable_path).resolve(strict=True)
        or "/LM Studio.app/" not in str(pathlib.Path(executable_path).resolve(strict=True))
    ):
        raise EvidenceSupportError("P10 provider is not a live LM Studio process")
    provider_binding = _stable_file_binding(
        pathlib.Path(executable_path).resolve(strict=True),
        artifact_id="lm-studio-provider-process",
        kind="app-executable",
    )
    request_document = {
        "model": model,
        "messages": [{
            "role": "user",
            "content": f"Return exactly this nonce and nothing else: {challenge_nonce}",
        }],
        "temperature": 0,
    }
    request_bytes = canonical_bytes(request_document)
    request = urllib.request.Request(
        endpoint,
        data=request_bytes,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            response_bytes = response.read(64 * 1024 + 1)
    except (OSError, urllib.error.URLError) as error:
        raise EvidenceSupportError(f"P10 LM Studio nonce request failed: {error}") from error
    if len(response_bytes) > 64 * 1024:
        raise EvidenceSupportError("P10 LM Studio nonce response exceeds its byte bound")
    response_document = decode_strict_json_object(response_bytes, label="P10 LM Studio nonce response")
    choices = response_document.get("choices")
    content = None
    if isinstance(choices, list) and len(choices) == 1 and isinstance(choices[0], dict):
        message = choices[0].get("message")
        if isinstance(message, dict):
            content = message.get("content")
    if (
        response_document.get("model") != model
        or not isinstance(response_document.get("id"), str)
        or not response_document["id"]
        or not isinstance(content, str)
        or content.strip() != challenge_nonce
    ):
        raise EvidenceSupportError("P10 LM Studio response did not acknowledge the exact nonce and model")
    return {
        "applicable": True,
        "kind": "lm_studio",
        "transport": "http",
        "real_provider": True,
        "endpoint": endpoint,
        "model": model,
        "provider_pid": pid,
        "provider_executable_path": str(pathlib.Path(executable_path).resolve(strict=True)),
        "provider_executable_sha256": provider_binding["sha256"],
        "provider_executable_bytes": provider_binding["bytes"],
        "challenge_nonce": challenge_nonce,
        "request_sha256": hashlib.sha256(request_bytes).hexdigest(),
        "response_sha256": hashlib.sha256(response_bytes).hexdigest(),
        "response_id": response_document["id"],
        "request_base64": base64.b64encode(request_bytes).decode("ascii"),
        "response_base64": base64.b64encode(response_bytes).decode("ascii"),
    }


def validate_provider_fact(
    binding: dict[str, Any],
    observation: dict[str, Any],
    fact: Any,
) -> bool:
    expected = binding.get("expected")
    required_keys = {
        "applicable", "kind", "transport", "real_provider", "endpoint", "model", "provider_pid",
        "provider_executable_path", "provider_executable_sha256", "provider_executable_bytes",
        "challenge_nonce", "request_sha256", "response_sha256", "response_id",
        "request_base64", "response_base64",
    }
    if (
        not isinstance(expected, dict)
        or not isinstance(fact, dict)
        or set(fact) != required_keys
        or fact.get("applicable") is not True
        or fact.get("kind") != "lm_studio"
        or fact.get("transport") != "http"
        or fact.get("real_provider") is not True
        or fact.get("endpoint") != expected.get("endpoint")
        or fact.get("model") != expected.get("model")
        or fact.get("challenge_nonce") != observation.get("challenge_nonce")
    ):
        return False
    process = observation.get("provider_process")
    if process != {
        "pid": fact.get("provider_pid"),
        "executable_path": fact.get("provider_executable_path"),
    }:
        return False
    try:
        request_raw = base64.b64decode(fact["request_base64"], validate=True)
        response_raw = base64.b64decode(fact["response_base64"], validate=True)
        request_document = decode_strict_json_object(request_raw, label="preserved LM Studio request")
        response_document = decode_strict_json_object(response_raw, label="preserved LM Studio response")
        executable = _stable_file_binding(
            pathlib.Path(fact["provider_executable_path"]).resolve(strict=True),
            artifact_id="lm-studio-provider-process",
            kind="app-executable",
        )
    except (OSError, KeyError, binascii.Error, ValueError, EvidenceSupportError):
        return False
    choices = response_document.get("choices")
    content = None
    if isinstance(choices, list) and len(choices) == 1 and isinstance(choices[0], dict):
        message = choices[0].get("message")
        if isinstance(message, dict):
            content = message.get("content")
    messages = request_document.get("messages")
    prompt = messages[0].get("content") if isinstance(messages, list) and len(messages) == 1 and isinstance(messages[0], dict) else None
    return (
        hashlib.sha256(request_raw).hexdigest() == fact.get("request_sha256")
        and hashlib.sha256(response_raw).hexdigest() == fact.get("response_sha256")
        and request_document.get("model") == fact.get("model")
        and isinstance(prompt, str)
        and prompt.endswith(fact.get("challenge_nonce", ""))
        and response_document.get("model") == fact.get("model")
        and response_document.get("id") == fact.get("response_id")
        and isinstance(content, str)
        and content.strip() == fact.get("challenge_nonce")
        and executable["sha256"] == fact.get("provider_executable_sha256")
        and executable["bytes"] == fact.get("provider_executable_bytes")
    )


def evaluate_probe_output(
    probe: dict[str, Any],
    stdout: bytes,
    stderr: bytes,
    *,
    exit_code: int,
    timed_out: bool,
    stream_limit_exceeded: bool,
) -> tuple[bool, int, int, dict[str, Any] | None]:
    # Runner stdout/stderr are diagnostics only. Production qualification is
    # sourced from a separately preserved, typed observation artifact.
    del probe, stdout, stderr, exit_code, timed_out, stream_limit_exceeded
    return False, 0, 0, None


def evaluate_runner_artifact(
    probe: dict[str, Any],
    raw: bytes,
    *,
    evidence_id: str,
    challenge_nonce: str,
) -> tuple[bool, dict[str, dict[str, Any]], dict[str, Any] | None]:
    """Accept only runner context and sensitive placeholders, never CLI outcomes."""

    try:
        document = decode_strict_json_object(raw, label="P10 scenario runner context")
    except EvidenceSupportError:
        return False, {}, None
    bindings = probe.get("assertions")
    bindings = bindings if isinstance(bindings, list) else []
    expected: dict[str, dict[str, Any]] = {}
    for binding in bindings:
        if not isinstance(binding, dict) or not isinstance(binding.get("selector"), str):
            return False, {}, document
        if binding.get("evidence_kind") not in {"codesign-identity", "lmstudio-nonce-transcript"}:
            continue
        selector = binding["selector"]
        prior = expected.get(selector)
        if prior is None:
            expected[selector] = binding
            continue
        if (
            binding.get("evidence_kind") != "codesign-identity"
            or prior.get("evidence_kind") != "codesign-identity"
            or binding.get("expected") != prior.get("expected")
        ):
            return False, {}, document
    results = document.get("results")
    if (
        set(document) != {
            "schema_version", "kind", "evidence_id", "scenario_id",
            "challenge_nonce", "process", "provider_process", "results",
        }
        or document.get("schema_version") != 2
        or document.get("kind") != "p10-runner-context"
        or document.get("evidence_id") != evidence_id
        or document.get("scenario_id") != probe.get("scenario_id")
        or document.get("challenge_nonce") != challenge_nonce
        or not isinstance(results, list)
        or len(results) != len(expected)
    ):
        return False, {}, document
    by_selector: dict[str, dict[str, Any]] = {}
    for result in results:
        if not isinstance(result, dict) or set(result) != {
            "selector", "evidence_kind", "request", "response",
        }:
            return False, {}, document
        selector = result.get("selector")
        binding = expected.get(selector)
        request = result.get("request")
        response = result.get("response")
        expected_value = binding.get("expected") if isinstance(binding, dict) else None
        if (
            binding is None
            or selector in by_selector
            or result.get("evidence_kind") != binding.get("evidence_kind")
            or result.get("evidence_kind") not in {
                "codesign-identity", "lmstudio-nonce-transcript",
            }
            or request != {"challenge_nonce": challenge_nonce, "selector": selector}
            or response != {
                "challenge_nonce": challenge_nonce,
                "selector": selector,
                "observed": expected_value,
            }
        ):
            return False, {}, document
        by_selector[selector] = result
    return set(by_selector) == set(expected), by_selector, document


def evaluate_probe_artifact(
    probe: dict[str, Any],
    raw: bytes,
    *,
    evidence_id: str,
    challenge_nonce: str,
    installation: dict[str, Any] | None = None,
    repository: pathlib.Path | None = None,
) -> tuple[bool, int, dict[str, dict[str, Any]], dict[str, Any] | None]:
    """Re-derive results from the qualifier-owned preserved observation."""

    try:
        document = decode_strict_json_object(raw, label="P10 qualifier observation")
    except EvidenceSupportError:
        return False, 0, {}, None
    bindings = probe.get("assertions")
    bindings = bindings if isinstance(bindings, list) else []
    expected: dict[str, dict[str, Any]] = {}
    for binding in bindings:
        if not isinstance(binding, dict) or not isinstance(binding.get("selector"), str):
            return False, 0, {}, document
        selector = binding["selector"]
        prior = expected.get(selector)
        if prior is None:
            expected[selector] = binding
            continue
        if (
            binding.get("evidence_kind") != "codesign-identity"
            or prior.get("evidence_kind") != "codesign-identity"
            or binding.get("expected") != prior.get("expected")
        ):
            return False, 0, {}, document
    results = document.get("results")
    if (
        set(document) != {
            "schema_version", "kind", "evidence_id", "scenario_id",
            "challenge_nonce", "process", "provider_process", "results",
        }
        or document.get("schema_version") != 3
        or document.get("kind") != "p10-qualifier-observations"
        or document.get("evidence_id") != evidence_id
        or document.get("scenario_id") != probe.get("scenario_id")
        or document.get("challenge_nonce") != challenge_nonce
        or not isinstance(results, list)
        or len(results) != len(expected)
    ):
        return False, 0, {}, document
    by_selector: dict[str, dict[str, Any]] = {}
    for result in results:
        if not isinstance(result, dict):
            return False, 0, {}, document
        selector = result.get("selector")
        binding = expected.get(selector)
        if binding is None or selector in by_selector:
            return False, 0, {}, document
        evidence_kind = binding.get("evidence_kind")
        if evidence_kind == "native-cli-version-help":
            if not (native_cli.scenario_valid(probe) or native_cli.scenario_valid(probe, allow_bound_root=True)) or repository is None or not native_cli.validate_result(repository, result, evidence_id=evidence_id, nonce=challenge_nonce, process=document.get("process")):
                return False, 0, {}, document
        elif evidence_kind == "installed-cli-transcript":
            if installation is None or not validate_installed_cli_transcript(
                binding,
                result,
                installation,
                challenge_nonce=challenge_nonce,
            ):
                return False, 0, {}, document
        elif evidence_kind in {"codesign-identity", "lmstudio-nonce-transcript"}:
            if (
                set(result) != {"selector", "evidence_kind", "request", "response"}
                or result.get("evidence_kind") != evidence_kind
                or result.get("request") != {
                    "challenge_nonce": challenge_nonce,
                    "selector": selector,
                }
                or result.get("response") != {
                    "challenge_nonce": challenge_nonce,
                    "selector": selector,
                    "observed": binding.get("expected"),
                }
            ):
                return False, 0, {}, document
        else:
            return False, 0, {}, document
        by_selector[selector] = result
    passed = set(by_selector) == set(expected)
    return passed, len(by_selector) if passed else 0, by_selector, document


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=str(pathlib.Path(__file__).resolve().parents[2]))
    parser.add_argument("--report", default=REPORT_PATH)
    parser.add_argument("--feature", choices=[native_cli.FEATURE_ID], help="Qualify exactly both registered assertions for this feature; full G10 coverage is still required")
    parser.add_argument("--build-evidence", help="Exact current-source ordinary development Release build recorder ID")
    parser.add_argument("--installation-evidence", help="Exact supported installation recorder ID with retained app")
    parser.add_argument(
        "--cli-app",
        help="Capture supporting version/help observations from this native app's embedded CLI; does not qualify P10 or establish installation/signing",
    )
    return parser


def main() -> int:
    arguments = build_parser().parse_args()
    repository = pathlib.Path(arguments.repo).resolve(strict=True)
    if arguments.report != REPORT_PATH:
        raise SystemExit("the production qualification report path is fixed")
    evidence_id = os.environ.get("FORGE_EVIDENCE_ID", "")
    if not evidence_id.startswith("EVID-"):
        raise SystemExit("the qualifier must run under record_command.py")
    registry, registry_raw = load_json(repository, FEATURE_REGISTRY_PATH, "P10 feature registry")
    probes, probes_raw = load_json(repository, PROBE_REGISTRY_PATH, "P10 production probe registry")
    baseline, baseline_raw = load_json(repository, FEATURE_BASELINE_PATH, "P10 feature baseline")
    required = {
        (feature["id"], assertion)
        for feature in registry.get("features", [])
        if isinstance(feature, dict)
        for assertion in feature.get("required_assertions", [])
        if isinstance(assertion, str)
    }
    global_required = set(required)
    if arguments.feature is not None:
        if arguments.cli_app is not None or not arguments.build_evidence or not arguments.installation_evidence:
            raise EvidenceSupportError("selected canonical CLI qualification requires build/install evidence and cannot use --cli-app")
        registry = {**registry, "features": [feature for feature in registry.get("features", []) if feature.get("id") == arguments.feature]}
        required = {item for item in required if item[0] == arguments.feature}
        if len(required) != 2:
            raise EvidenceSupportError("selected CLI feature must retain its exact two required assertions")
    expected_limits = {
        "maximum_matrix_seconds": MAXIMUM_MATRIX_SECONDS,
        "maximum_probe_stream_bytes": MAXIMUM_STREAM_BYTES_PER_PROBE,
        "maximum_observation_bytes_per_scenario": MAXIMUM_OBSERVATION_BYTES_PER_SCENARIO,
        "maximum_total_raw_output_bytes": MAXIMUM_TOTAL_RAW_OUTPUT_BYTES,
        "maximum_unique_runners": MAXIMUM_UNIQUE_RUNNERS,
    }
    if probes.get("limits") != expected_limits:
        raise EvidenceSupportError("P10 production probe bounds are not canonical")
    implemented = probes.get("implemented_scenarios")
    implemented = implemented if isinstance(implemented, list) else []
    if arguments.feature is not None:
        implemented = [scenario for scenario in implemented if scenario.get("runner", {}).get("kind") == native_cli.RUNNER_KIND]
    if len(implemented) > MAXIMUM_UNIQUE_RUNNERS:
        raise EvidenceSupportError("P10 production probe matrix exceeds the unique-runner bound")
    scenario_ids = [
        scenario.get("scenario_id") for scenario in implemented if isinstance(scenario, dict)
    ]
    runner_bindings = [runner_identity(scenario) for scenario in implemented if isinstance(scenario, dict)]
    if len(scenario_ids) != len(set(scenario_ids)) or len(runner_bindings) != len(set(runner_bindings)):
        raise EvidenceSupportError("P10 production scenarios contain duplicate IDs or runners instead of grouping")
    mapped = {
        (binding.get("feature_id"), binding.get("assertion_id"))
        for scenario in implemented
        if isinstance(scenario, dict)
        for binding in scenario.get("assertions", [])
        if isinstance(binding, dict)
    }
    registry_by_id = {
        feature.get("id"): feature
        for feature in registry.get("features", [])
        if isinstance(feature, dict) and isinstance(feature.get("id"), str)
    }
    canonical_feature_registry = (
        registry.get("registry_id") == CANONICAL_FEATURE_REGISTRY_ID
    )
    for scenario in implemented:
        for binding in scenario.get("assertions", []) if isinstance(scenario, dict) else []:
            assertion_id = binding.get("assertion_id") if isinstance(binding, dict) else None
            feature = registry_by_id.get(binding.get("feature_id")) if isinstance(binding, dict) else None
            if isinstance(assertion_id, str) and assertion_id.endswith(".production-path"):
                if native_cli.scenario_valid(scenario) and binding == native_cli.SCENARIO["assertions"][0]:
                    continue
                if canonical_feature_registry and isinstance(feature, dict) and feature.get("category") == "cli":
                    raise EvidenceSupportError(
                        "P10 canonical CLI assertions have no reviewed snapshot-safe semantic contract"
                    )
                if (
                    not isinstance(feature, dict)
                    or feature.get("category") != "cli"
                    or binding.get("evidence_kind") != "installed-cli-transcript"
                    or not installed_cli_contract_valid(binding.get("expected"))
                ):
                    raise EvidenceSupportError(
                        "P10 ordinary production assertions are supported only by the trusted installed CLI adapter"
                    )
    missing = sorted(required - mapped)
    if missing:
        diagnostic = {
            "schema_version": 1,
            "kind": "p10-production-probe-gap",
            "missing_probe_count": len(missing),
            "missing_assertions": [assertion for _, assertion in missing],
        }
        print(json.dumps(diagnostic, sort_keys=True, separators=(",", ":")))

    command_argv = [str(pathlib.Path(__file__).resolve()), "--report", REPORT_PATH]
    if arguments.feature is not None:
        command_argv.extend(["--feature", arguments.feature])
    if arguments.build_evidence is not None:
        command_argv.extend(["--build-evidence", arguments.build_evidence])
    if arguments.installation_evidence is not None:
        command_argv.extend(["--installation-evidence", arguments.installation_evidence])
    if arguments.cli_app is not None:
        command_argv.extend(["--cli-app", arguments.cli_app])
    started_at = now()
    matrix_deadline = time.monotonic() + MAXIMUM_MATRIX_SECONDS
    execution_environment = probe_environment()
    receipts: list[dict[str, Any]] = []
    rows_by_feature: dict[str, list[dict[str, Any]]] = {}
    signing_by_feature: dict[str, dict[str, Any]] = {}
    provider_by_feature: dict[str, dict[str, Any]] = {}
    observation_documents: list[dict[str, Any]] = []
    installation_receipts: list[dict[str, Any]] = []
    aggregate_output_bytes = 0
    supporting_cli = None
    if arguments.cli_app is not None:
        feature = registry_by_id.get("CLI-VERSION-HELP")
        if not isinstance(feature, dict) or "CLI-VERSION-HELP.production-path" not in feature.get("required_assertions", []):
            raise EvidenceSupportError("CLI supporting capture is not associated with the current feature registry")
        from p10_cli_version_help import capture
        supporting_cli = capture(
            repository, pathlib.Path(arguments.cli_app),
            evidence_id=evidence_id, challenge_nonce=secrets.token_hex(32),
        )
        aggregate_output_bytes += supporting_cli["bytes"]
    for probe in implemented:
        if probe.get("runner", {}).get("kind") == native_cli.RUNNER_KIND:
            probe_started = now()
            probe_deadline = time.monotonic() + bounded_remaining_seconds(matrix_deadline, probe["runner"]["timeout_seconds"])
            challenge_nonce = secrets.token_hex(32)
            stdout, stderr = b"", b""
            timed_out = stream_limit_exceeded = False
            scenario_signing, scenario_providers = {}, {}
            installation_facts = result_document = None
            observation_raw = b""
            argv, _ = runner_argv(repository, probe)
            exit_code, passed = 1, False
            try:
                if not arguments.build_evidence or not arguments.installation_evidence:
                    raise EvidenceSupportError("registered native CLI scenario requires build and installation evidence IDs")
                probe, native_result, process = native_cli.capture_result(
                    repository, build_id=arguments.build_evidence,
                    installation_id=arguments.installation_evidence,
                    evidence_id=evidence_id, nonce=challenge_nonce,
                )
                argv, _ = runner_argv(repository, probe)
                signing_binding = probe["assertions"][1]
                result_document = {
                    "schema_version": 3, "kind": "p10-qualifier-observations",
                    "evidence_id": evidence_id, "scenario_id": probe["scenario_id"],
                    "challenge_nonce": challenge_nonce, "process": process,
                    "provider_process": None, "results": [native_result, {
                        "selector": signing_binding["selector"], "evidence_kind": "codesign-identity",
                        "request": {"challenge_nonce": challenge_nonce, "selector": signing_binding["selector"]},
                        "response": {"challenge_nonce": challenge_nonce, "selector": signing_binding["selector"], "observed": signing_binding["expected"]},
                    }],
                }
                installation_facts = derive_installation_facts(probe, result_document, require_live_process=False)
                scenario_signing[signing_binding["selector"]] = derive_signing_fact(signing_binding, installation_facts)
                installation_receipts.append(installation_facts)
                observation_raw = canonical_bytes(result_document)
                exit_code, passed = 0, True
            except (OSError, ValueError, EvidenceSupportError, subprocess.SubprocessError) as error:
                stderr = str(error).encode("utf-8")[:MAXIMUM_STREAM_BYTES_PER_PROBE]
                print(f"P10 native CLI scenario rejected: {error}", file=sys.stderr)
        else:
            argv, timeout = runner_argv(repository, probe)
            timeout = bounded_remaining_seconds(matrix_deadline, timeout)
            probe_started = now()
            challenge_nonce = secrets.token_hex(32)
            with tempfile.TemporaryDirectory(prefix="forge-p10-probe-") as temporary:
                temporary_root = pathlib.Path(temporary)
                stdout_path = temporary_root / "stdout"
                stderr_path = temporary_root / "stderr"
                observation_path = temporary_root / "observation.json"
                scenario_environment = {
                    **execution_environment,
                    "FORGE_EVIDENCE_ID": evidence_id,
                    "FORGE_P10_SCENARIO_ID": probe["scenario_id"],
                    "FORGE_P10_CHALLENGE_NONCE": challenge_nonce,
                    "FORGE_P10_OBSERVATION_PATH": str(observation_path),
                }
                exit_code, timed_out, stream_limit_exceeded = execute_command(
                    argv,
                    repository,
                    stdout_path,
                    stderr_path,
                    timeout,
                    MAXIMUM_STREAM_BYTES_PER_PROBE,
                    scenario_environment,
                )
                stdout = stdout_path.read_bytes()
                stderr = stderr_path.read_bytes()
                try:
                    observation_size = observation_path.stat().st_size
                    if observation_size < 1 or observation_size > MAXIMUM_STREAM_BYTES_PER_PROBE:
                        raise EvidenceSupportError("P10 scenario observation exceeds its exact byte bound")
                    observation_raw = observation_path.read_bytes()
                except OSError:
                    observation_raw = b""
            runner_observation_raw = observation_raw
            aggregate_output_bytes += len(stdout) + len(stderr) + len(runner_observation_raw)
            if aggregate_output_bytes > MAXIMUM_TOTAL_RAW_OUTPUT_BYTES:
                raise EvidenceSupportError("P10 production probe matrix exceeded its aggregate output bound")
            runner_passed, runner_results, runner_document = evaluate_runner_artifact(
                probe,
                runner_observation_raw,
                evidence_id=evidence_id,
                challenge_nonce=challenge_nonce,
            )
            passed = runner_passed
            installation_facts: dict[str, Any] | None = None
            scenario_signing: dict[str, dict[str, Any]] = {}
            scenario_providers: dict[str, dict[str, Any]] = {}
            if isinstance(runner_document, dict):
                try:
                    installation_facts = derive_installation_facts(
                        probe,
                        runner_document,
                        require_live_process=True,
                    )
                except (OSError, UnicodeDecodeError, EvidenceSupportError, subprocess.SubprocessError) as error:
                    print(
                        f"P10 scenario {probe['scenario_id']} installation rejected: {error}",
                        file=sys.stderr,
                    )
                    passed = False
                else:
                    installation_receipts.append(installation_facts)
                    for binding in probe["assertions"]:
                        assertion_id = binding["assertion_id"]
                        try:
                            if signing_artifact_from_assertion(assertion_id) is not None:
                                selector = binding["selector"]
                                if selector not in scenario_signing:
                                    scenario_signing[selector] = derive_signing_fact(
                                        binding,
                                        installation_facts,
                                    )
                            elif assertion_id.endswith(".real-provider"):
                                scenario_providers[binding["selector"]] = derive_provider_fact(
                                    binding,
                                    runner_document,
                                    challenge_nonce=challenge_nonce,
                                )
                        except (OSError, UnicodeDecodeError, EvidenceSupportError, subprocess.SubprocessError) as error:
                            print(
                                f"P10 scenario {probe['scenario_id']} sensitive fact rejected: {error}",
                                file=sys.stderr,
                            )
                            passed = False
            qualifier_results: list[dict[str, Any]] = []
            seen_selectors: set[str] = set()
            if isinstance(runner_document, dict):
                for binding in probe["assertions"]:
                    selector = binding["selector"]
                    if selector in seen_selectors:
                        continue
                    seen_selectors.add(selector)
                    if binding.get("evidence_kind") == "installed-cli-transcript":
                        try:
                            if installation_facts is None:
                                raise EvidenceSupportError("P10 installed CLI observation has no installation receipt")
                            qualifier_results.append(capture_installed_cli_transcript(
                                binding,
                                installation_facts,
                                challenge_nonce=challenge_nonce,
                                matrix_deadline=matrix_deadline,
                            ))
                        except (OSError, UnicodeDecodeError, EvidenceSupportError, subprocess.SubprocessError) as error:
                            print(
                                f"P10 scenario {probe['scenario_id']} CLI observation rejected: {error}",
                                file=sys.stderr,
                            )
                            passed = False
                    else:
                        sensitive_result = runner_results.get(selector)
                        if isinstance(sensitive_result, dict):
                            qualifier_results.append(sensitive_result)
                        else:
                            passed = False
                result_document = {
                    "schema_version": 3,
                    "kind": "p10-qualifier-observations",
                    "evidence_id": evidence_id,
                    "scenario_id": probe["scenario_id"],
                    "challenge_nonce": challenge_nonce,
                    "process": runner_document.get("process"),
                    "provider_process": runner_document.get("provider_process"),
                    "results": qualifier_results,
                }
                observation_raw = canonical_bytes(result_document)
            else:
                result_document = None
                observation_raw = b""
        if probe.get("runner", {}).get("kind") == native_cli.RUNNER_KIND:
            aggregate_output_bytes += len(stdout) + len(stderr)
            if time.monotonic() > probe_deadline:
                timed_out, passed = True, False
        if len(observation_raw) > MAXIMUM_OBSERVATION_BYTES_PER_SCENARIO:
            raise EvidenceSupportError("P10 qualifier observation exceeds its exact byte bound")
        aggregate_output_bytes += len(observation_raw)
        if aggregate_output_bytes > MAXIMUM_TOTAL_RAW_OUTPUT_BYTES:
            raise EvidenceSupportError("P10 production probe matrix exceeded its aggregate output bound")
        observed_pass, executed_tests, result_by_selector, parsed_result_document = evaluate_probe_artifact(
            probe,
            observation_raw,
            evidence_id=evidence_id,
            challenge_nonce=challenge_nonce,
            installation=installation_facts,
            repository=repository,
        )
        if parsed_result_document != result_document:
            passed = False
        passed = (
            passed
            and observed_pass
            and exit_code == 0
            and not timed_out
            and not stream_limit_exceeded
        )
        observed_assertions = len(result_by_selector)
        observation_sha256 = hashlib.sha256(observation_raw).hexdigest()
        if isinstance(result_document, dict):
            observation_documents.append({
                "scenario_id": probe["scenario_id"],
                "challenge_nonce": challenge_nonce,
                "sha256": observation_sha256,
                "bytes": len(observation_raw),
                "document_base64": base64.b64encode(observation_raw).decode("ascii"),
                "installation": installation_facts,
                "signing": scenario_signing,
                "providers": scenario_providers,
            })
        receipt = {
            "schema_version": 1,
            "kind": "p10-production-probe-receipt",
            "scenario_id": probe["scenario_id"],
            "assertions": probe["assertions"],
            "runner": probe["runner"],
            "runner_argv": argv,
            "runner_environment": execution_environment,
            "challenge_nonce": challenge_nonce,
            "observation_sha256": observation_sha256,
            "observation_bytes": len(observation_raw),
            "started_at": probe_started,
            "ended_at": now(),
            "exit_code": exit_code,
            "timed_out": timed_out,
            "stream_limit_exceeded": stream_limit_exceeded,
            "executed_tests": executed_tests,
            "observed_assertions": observed_assertions,
            "stdout_base64": base64.b64encode(stdout).decode("ascii"),
            "stderr_base64": base64.b64encode(stderr).decode("ascii"),
        }
        receipt_sha = hashlib.sha256(canonical_bytes(receipt)).hexdigest()
        print(json.dumps(receipt, sort_keys=True, separators=(",", ":")), flush=True)
        for binding in probe["assertions"]:
            assertion_id = binding["assertion_id"]
            selector = binding["selector"]
            selected = result_by_selector.get(selector)
            assertion_observations = 1 if isinstance(selected, dict) else 0
            assertion_passed = passed and isinstance(selected, dict)
            if signing_artifact_from_assertion(assertion_id) is not None:
                signing = scenario_signing.get(selector)
                assertion_passed = assertion_passed and isinstance(signing, dict)
                if isinstance(signing, dict):
                    signing_by_feature[binding["feature_id"]] = signing
            if assertion_id.endswith(".real-provider"):
                provider = scenario_providers.get(selector)
                assertion_passed = assertion_passed and isinstance(provider, dict)
                if isinstance(provider, dict):
                    provider_by_feature[binding["feature_id"]] = provider
            assertion = {
                "id": assertion_id,
                "scenario_id": probe["scenario_id"],
                "selector": selector,
                "runner_kind": probe["runner"]["kind"],
                "runner_argv": argv,
                "execution_receipt_sha256": receipt_sha,
                "executed_tests": executed_tests,
                "observed_assertions": assertion_observations,
                "passed": assertion_passed,
                "result": "passed" if assertion_passed else "failed",
                "artifact_references": [{
                    "source_path": OBSERVATION_PATH,
                    "scenario_id": probe["scenario_id"],
                    "selector": selector,
                    "sha256": observation_sha256,
                }],
            }
            rows_by_feature.setdefault(binding["feature_id"], []).append(assertion)
        receipts.append(receipt)
    ended_at = now()
    rows: list[dict[str, Any]] = []
    for feature in registry["features"]:
        assertions = rows_by_feature.get(feature["id"], [])
        assertion_order = {
            assertion_id: index for index, assertion_id in enumerate(feature["required_assertions"])
        }
        assertions.sort(key=lambda item: assertion_order.get(item["id"], len(assertion_order)))
        signing = signing_by_feature.get(
            feature["id"],
            {
                "applicable": False,
                "artifact_id": None,
                "path": None,
                "artifact_sha256": None,
                "artifact_bytes": None,
                "team_id": None,
                "identifier": None,
                "cdhash": None,
                "designated_requirement_sha256": None,
                "hardened_runtime": None,
            },
        )
        provider = provider_by_feature.get(
            feature["id"],
            {
                "applicable": False,
                "kind": "not_applicable",
                "transport": None,
                "endpoint": None,
                "model": None,
                "real_provider": False,
                "provider_pid": None,
                "provider_executable_path": None,
                "provider_executable_sha256": None,
                "provider_executable_bytes": None,
                "challenge_nonce": None,
                "request_sha256": None,
                "response_sha256": None,
                "response_id": None,
                "request_base64": None,
                "response_base64": None,
            },
        )
        rows.append(
            {
                "feature_id": feature["id"],
                "status": (
                    "not_run" if not assertions else
                    "failed" if not all(item["passed"] for item in assertions) else
                    "partial" if len(assertions) < len(feature["required_assertions"]) else
                    "passed"
                ),
                "execution_count": sum(item["executed_tests"] for item in assertions),
                "assertion_count": len(assertions),
                "assertions": assertions,
                "signing": signing,
                "provider": provider,
            }
        )
    assertion_count = sum(len(row["assertions"]) for row in rows)
    passed_count = sum(1 for row in rows for item in row["assertions"] if item["passed"])
    manifest = source_manifest(repository)
    observation_aggregate = {
        "schema_version": 1,
        "kind": "p10-production-observation-aggregate",
        "evidence_id": evidence_id,
        "scenarios": observation_documents,
    }
    atomic_write_json(repository / OBSERVATION_PATH, observation_aggregate)
    installation_receipt = installation_receipts[0] if installation_receipts and all(
        item == installation_receipts[0] for item in installation_receipts
    ) and len(installation_receipts) == len(receipts) else None
    incomplete = bool(missing) or not required or assertion_count != len(required)
    exit_code = 2 if incomplete else (0 if passed_count == assertion_count else 1)
    report = {
        "schema_version": 2,
        "qualifier": EXPECTED_QUALIFIER,
        "command": {
            "argv": command_argv,
            "exit_code": exit_code,
            "timed_out": False,
            "stream_limit_exceeded": False,
        },
        "execution": {
            "count": len(receipts),
            "assertion_count": assertion_count,
            "passed_assertion_count": passed_count,
            "failed_assertion_count": assertion_count - passed_count,
        },
        "environment": {
            "repository": str(repository),
            "platform": os.environ.get("FORGE_EVIDENCE_PLATFORM", platform.platform()),
            "architecture": os.environ.get("FORGE_EVIDENCE_ARCHITECTURE", platform.machine()),
            "macos_build": os.environ.get("FORGE_EVIDENCE_MACOS_BUILD", platform.version()),
            "machine_identifier": os.environ.get("FORGE_EVIDENCE_MACHINE_IDENTIFIER", "unknown"),
            "configuration": "Release",
            "installed_product": not incomplete and installation_receipt is not None and passed_count == assertion_count,
            "installation_receipt": installation_receipt,
        },
        "timing": {"started_at": started_at, "ended_at": ended_at},
        "source_identity": {
            "git_head": current_git_head(repository),
            "source_manifest": manifest,
            "registry_sha256": hashlib.sha256(registry_raw).hexdigest(),
            "probe_registry_sha256": hashlib.sha256(probes_raw).hexdigest(),
            "qualifier_sha256": hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
            "baseline_sha256": hashlib.sha256(baseline_raw).hexdigest(),
        },
        "results": rows,
    }
    if arguments.feature is not None:
        report["selection"] = {
            "feature_ids": [native_cli.FEATURE_ID], "scope": native_cli.SCOPE,
            "distribution_qualified": False,
            "global_required_assertion_count": len(global_required),
            "global_missing_assertion_ids": sorted(assertion for feature, assertion in global_required - mapped),
            "build_evidence_id": arguments.build_evidence,
            "installation_evidence_id": arguments.installation_evidence,
        }
    if incomplete or supporting_cli is not None:
        # Passing-only production reports keep their existing schema. A partial
        # report preserves real observations without entering that acceptance path.
        report["schema_version"] = 3
        report["kind"] = "p10-feature-partial-qualification"
        report["coverage"] = {
            "required_assertion_count": len(required),
            "mapped_assertion_count": len(required & mapped),
            "missing_assertion_count": len(missing),
            "missing_assertions": [assertion for _, assertion in missing],
            "complete": False,
        }
        report["supporting_cli"] = supporting_cli
        if not installation_receipts:
            report["environment"]["configuration"] = "not_assessed"
        report["environment"]["installed_product"] = False
        report["command"]["exit_code"] = 2
        exit_code = 2
    atomic_write_json(repository / REPORT_PATH, report)
    return exit_code


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, EvidenceSupportError, ValueError) as error:
        print(f"P10 qualification failed closed: {error}", file=sys.stderr)
        raise SystemExit(2)
