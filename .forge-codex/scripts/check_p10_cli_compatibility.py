#!/usr/bin/env python3
"""Validate the preserved Forge Conductor CLI contract with bounded subprocesses."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import selectors
import signal
import subprocess
import sys
import tempfile
import time
from typing import Any

from evidence_support import source_manifest


ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_BASELINE = ROOT / ".forge-codex/state/baseline/cli-contract.json"
VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
CASE_ID_PATTERN = re.compile(r"^[a-z0-9_]+$")
REVISION_PATTERN = re.compile(r"^[0-9a-f]{40}$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")

EXPECTED_BASELINE_REVISION = "1fce9e0188698167564056ee8ace266342f97c7b"
EXPECTED_BASELINE_SHA256 = "edf08598ccf98f606ae0617528a714910d06cfd9e9a37dea0fd947874e7f2825"
EXPECTED_BASELINE_SOURCE_SHA256 = "c8cac41fd648b848b162ac193f5f32a67768ad864b4f66017147268e7aa9f7cf"
EXPECTED_BASELINE_VERSION = "0.8.0"
EXPECTED_SOURCE_PATH = "Sources/ForgeConductorCLI/ForgeConductorMain.swift"
EXPECTED_TOP_LEVEL_COMMANDS = (
    "install",
    "install-lmstudio-plugin",
    "doctor",
    "status",
    "serve",
    "dashboard",
    "manager",
    "agents",
    "version",
    "help",
)
EXPECTED_MANAGER_SUBCOMMANDS = (
    "run",
    "start",
    "stop",
    "restart",
    "status",
    "install-login",
    "uninstall-login",
    "cleanup-stale",
    "allowlist",
)
EXPECTED_PRESERVED_OPTIONS = {
    "shared_after_command": ["--home PATH"],
    "install": ["--from PATH"],
    "install-lmstudio-plugin": ["--binary PATH"],
    "dashboard": ["--host HOST", "--port PORT", "--open"],
    "manager": ["--open", "--home PATH", "install-login --keep-stale"],
}
PRESERVED_OPTION_HELP_CASES = {
    "shared_after_command": ("no_arguments_help", "manager_help"),
    "install": ("no_arguments_help",),
    "install-lmstudio-plugin": ("no_arguments_help",),
    "dashboard": ("no_arguments_help",),
    "manager": ("manager_help",),
}
TOP_LEVEL_OPTION_COMMANDS = {
    "install": "install",
    "install-lmstudio-plugin": "install-lmstudio-plugin",
    "dashboard": "dashboard",
}

SAFE_CASES: dict[str, dict[str, Any]] = {
    "no_arguments_help": {
        "arguments": [], "validator": "top_level_help", "expected_exit": 0, "expected_stderr": "",
    },
    "help": {
        "arguments": ["help"], "validator": "top_level_help", "expected_exit": 0, "expected_stderr": "",
    },
    "short_help": {
        "arguments": ["-h"], "validator": "top_level_help", "expected_exit": 0, "expected_stderr": "",
    },
    "long_help": {
        "arguments": ["--help"], "validator": "top_level_help", "expected_exit": 0, "expected_stderr": "",
    },
    "version": {
        "arguments": ["version"], "validator": "version", "expected_exit": 0, "expected_stderr": "",
    },
    "long_version": {
        "arguments": ["--version"], "validator": "version", "expected_exit": 0, "expected_stderr": "",
    },
    "unknown_command": {
        "arguments": ["__forge_unknown_command__"],
        "validator": "top_level_help",
        "expected_exit": 2,
        "expected_stderr": "Unknown command: __forge_unknown_command__\n\n",
    },
    "manager_help": {
        "arguments": ["manager", "help"], "validator": "manager_help", "expected_exit": 0, "expected_stderr": "",
    },
    "manager_short_help": {
        "arguments": ["manager", "-h"], "validator": "manager_help", "expected_exit": 0, "expected_stderr": "",
    },
    "manager_long_help": {
        "arguments": ["manager", "--help"], "validator": "manager_help", "expected_exit": 0, "expected_stderr": "",
    },
    "manager_unknown_command": {
        "arguments": ["manager", "__forge_unknown_manager_command__"],
        "validator": "empty_stdout",
        "expected_exit": 2,
        "expected_stdout": "",
        "expected_stderr": "Unknown manager subcommand: __forge_unknown_manager_command__\n",
    },
    "status": {
        "arguments": ["status", "--home", "{home}"],
        "validator": "status_json",
        "expected_exit": 0,
        "expected_stderr": "",
    },
    "doctor": {
        "arguments": ["doctor", "--home", "{home}"],
        "validator": "doctor_json",
        "expected_exit": "json_ok",
        "expected_stderr": "",
    },
    "agents": {
        "arguments": ["agents", "--home", "{home}"],
        "validator": "agents_tsv",
        "expected_exit": 0,
        "expected_stderr": "",
    },
    "manager_status": {
        "arguments": ["manager", "status", "--home", "{home}"],
        "validator": "manager_status_json",
        "expected_exit": 0,
        "expected_stderr": "",
    },
    "manager_stop_idle": {
        "arguments": ["manager", "stop", "--home", "{home}"],
        "validator": "manager_stop_idle",
        "expected_exit": 0,
        "expected_stdout": "Manager is not running\n",
        "expected_stderr": "",
    },
}

EXPECTED_EQUIVALENCE_GROUPS = {
    "top_level_help": (
        "no_arguments_help",
        "help",
        "short_help",
        "long_help",
    ),
    "version": ("version", "long_version"),
    "manager_help": (
        "manager_help",
        "manager_short_help",
        "manager_long_help",
    ),
}


class CheckFailure(RuntimeError):
    """A compatibility requirement was not met."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise CheckFailure(message)


def digest(path: pathlib.Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def resolve_repo_path(raw: str | pathlib.Path) -> pathlib.Path:
    candidate = pathlib.Path(raw)
    if not candidate.is_absolute():
        candidate = ROOT / candidate
    resolved = candidate.resolve()
    try:
        resolved.relative_to(ROOT)
    except ValueError as error:
        raise CheckFailure(f"path escapes repository: {raw}") from error
    return resolved


def load_contract(path: pathlib.Path) -> dict[str, Any]:
    require(path.is_file(), f"CLI baseline is missing: {path}")
    require(digest(path) == EXPECTED_BASELINE_SHA256, "CLI baseline digest changed")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise CheckFailure(f"cannot read CLI baseline: {error}") from error
    require(isinstance(value, dict), "CLI baseline must be a JSON object")
    expected_keys = {
        "schema_version",
        "captured_at",
        "baseline_revision",
        "baseline_source_sha256",
        "source_path",
        "baseline_version",
        "limits",
        "top_level_commands",
        "manager_subcommands",
        "preserved_options",
        "exit_code_contract",
        "equivalence_groups",
        "runtime_cases",
    }
    require(set(value) == expected_keys, "CLI baseline has missing or unknown top-level keys")
    require(value["schema_version"] == 1, "unsupported CLI baseline schema")
    require(
        isinstance(value["baseline_revision"], str)
        and REVISION_PATTERN.fullmatch(value["baseline_revision"]) is not None,
        "invalid baseline revision",
    )
    require(value["baseline_revision"] == EXPECTED_BASELINE_REVISION, "baseline revision changed")
    require(
        isinstance(value["baseline_source_sha256"], str)
        and SHA256_PATTERN.fullmatch(value["baseline_source_sha256"]) is not None,
        "invalid baseline source digest",
    )
    require(
        value["baseline_source_sha256"] == EXPECTED_BASELINE_SOURCE_SHA256,
        "baseline source digest changed",
    )
    require(
        isinstance(value["baseline_version"], str)
        and VERSION_PATTERN.fullmatch(value["baseline_version"]) is not None,
        "invalid baseline version",
    )
    require(value["baseline_version"] == EXPECTED_BASELINE_VERSION, "baseline version changed")
    require(value["source_path"] == EXPECTED_SOURCE_PATH, "CLI source path changed")
    validate_string_list(value["top_level_commands"], "top-level commands")
    validate_string_list(value["manager_subcommands"], "manager subcommands")
    require(
        tuple(value["top_level_commands"]) == EXPECTED_TOP_LEVEL_COMMANDS,
        "baseline top-level commands changed",
    )
    require(
        tuple(value["manager_subcommands"]) == EXPECTED_MANAGER_SUBCOMMANDS,
        "baseline manager subcommands changed",
    )
    require(value["preserved_options"] == EXPECTED_PRESERVED_OPTIONS, "baseline options changed")
    validate_limits(value["limits"])
    validate_exit_codes(value["exit_code_contract"])
    validate_equivalence_groups(value["equivalence_groups"])
    validate_cases(value["runtime_cases"])
    return value


def validate_string_list(value: Any, label: str) -> None:
    require(isinstance(value, list) and value, f"{label} must be a nonempty list")
    require(all(isinstance(item, str) and item for item in value), f"invalid {label}")
    require(len(set(value)) == len(value), f"duplicate {label}")


def validate_limits(value: Any) -> None:
    require(isinstance(value, dict), "limits must be an object")
    require(
        set(value)
        == {
            "case_timeout_seconds",
            "termination_grace_seconds",
            "maximum_stdout_bytes",
            "maximum_stderr_bytes",
        },
        "limits have missing or unknown keys",
    )
    timeout = value["case_timeout_seconds"]
    grace = value["termination_grace_seconds"]
    stdout_limit = value["maximum_stdout_bytes"]
    stderr_limit = value["maximum_stderr_bytes"]
    require(isinstance(timeout, int) and 1 <= timeout <= 30, "case timeout must be 1...30 seconds")
    require(isinstance(grace, int) and 1 <= grace <= 5, "termination grace must be 1...5 seconds")
    require(
        isinstance(stdout_limit, int) and 1024 <= stdout_limit <= 1024 * 1024,
        "stdout limit must be 1 KiB...1 MiB",
    )
    require(
        isinstance(stderr_limit, int) and 1024 <= stderr_limit <= 1024 * 1024,
        "stderr limit must be 1 KiB...1 MiB",
    )


def validate_exit_codes(value: Any) -> None:
    require(
        value == {"success": 0, "runtime_failure": 1, "unknown_command": 2},
        "CLI exit-code contract changed",
    )


def validate_equivalence_groups(value: Any) -> None:
    require(isinstance(value, list), "equivalence groups must be a list")
    observed: dict[str, tuple[str, ...]] = {}
    for group in value:
        require(
            isinstance(group, dict) and set(group) == {"id", "case_ids"},
            "invalid equivalence group",
        )
        group_id = group["id"]
        case_ids = group["case_ids"]
        require(isinstance(group_id, str), "equivalence group id must be a string")
        validate_string_list(case_ids, f"case ids for {group_id}")
        observed[group_id] = tuple(case_ids)
    require(observed == EXPECTED_EQUIVALENCE_GROUPS, "CLI alias groups changed")


def validate_cases(value: Any) -> None:
    require(isinstance(value, list), "runtime cases must be a list")
    require(len(value) == len(SAFE_CASES), "runtime case count changed")
    seen: set[str] = set()
    for case in value:
        require(isinstance(case, dict), "runtime case must be an object")
        allowed_keys = {
            "id",
            "arguments",
            "validator",
            "expected_exit",
            "expected_stdout",
            "expected_stderr",
        }
        require(set(case) <= allowed_keys, "runtime case has an unknown key")
        require(
            {"id", "arguments", "validator", "expected_exit", "expected_stderr"} <= set(case),
            "runtime case is missing a required key",
        )
        case_id = case["id"]
        require(
            isinstance(case_id, str) and CASE_ID_PATTERN.fullmatch(case_id) is not None,
            "invalid runtime case id",
        )
        require(case_id not in seen, f"duplicate runtime case: {case_id}")
        seen.add(case_id)
        require(case_id in SAFE_CASES, f"runtime case is not allowlisted: {case_id}")
        require(case == {"id": case_id, **SAFE_CASES[case_id]}, f"changed contract for {case_id}")
        expected_exit = case["expected_exit"]
        require(
            expected_exit in (0, 2, "json_ok"),
            f"invalid expected exit for {case_id}",
        )
        require(isinstance(case["expected_stderr"], str), f"invalid stderr contract for {case_id}")
        if "expected_stdout" in case:
            require(isinstance(case["expected_stdout"], str), f"invalid stdout contract for {case_id}")
    require(seen == set(SAFE_CASES), "runtime cases are incomplete")


def terminate_process_group(process: subprocess.Popen[bytes], grace_seconds: int) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + grace_seconds
    while process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.01)
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=grace_seconds)
    except subprocess.TimeoutExpired as error:
        raise CheckFailure("subprocess did not terminate after SIGKILL") from error


def run_bounded(
    command: list[str],
    environment: dict[str, str],
    *,
    timeout_seconds: int,
    termination_grace_seconds: int,
    maximum_stdout_bytes: int,
    maximum_stderr_bytes: int,
) -> tuple[int, bytes, bytes, int]:
    started = time.monotonic()
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            cwd=ROOT,
            start_new_session=True,
        )
    except OSError as error:
        raise CheckFailure(f"cannot launch CLI: {error}") from error

    require(process.stdout is not None and process.stderr is not None, "subprocess pipes are absent")
    streams = {
        process.stdout.fileno(): ("stdout", process.stdout, maximum_stdout_bytes),
        process.stderr.fileno(): ("stderr", process.stderr, maximum_stderr_bytes),
    }
    output = {"stdout": bytearray(), "stderr": bytearray()}
    selector = selectors.DefaultSelector()
    for descriptor, (name, _, _) in streams.items():
        os.set_blocking(descriptor, False)
        selector.register(descriptor, selectors.EVENT_READ, data=name)

    deadline = started + timeout_seconds
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                terminate_process_group(process, termination_grace_seconds)
                raise CheckFailure(f"subprocess timed out after {timeout_seconds} seconds")
            events = selector.select(timeout=min(0.1, remaining))
            for key, _ in events:
                descriptor = key.fd
                name, stream, limit = streams[descriptor]
                try:
                    chunk = os.read(descriptor, min(65536, limit - len(output[name]) + 1))
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(descriptor)
                    stream.close()
                    continue
                if len(output[name]) + len(chunk) > limit:
                    terminate_process_group(process, termination_grace_seconds)
                    raise CheckFailure(f"subprocess exceeded {name} limit of {limit} bytes")
                output[name].extend(chunk)

        if process.poll() is None:
            remaining = max(0.01, deadline - time.monotonic())
            try:
                process.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                terminate_process_group(process, termination_grace_seconds)
                raise CheckFailure(f"subprocess timed out after {timeout_seconds} seconds")
        return (
            int(process.returncode),
            bytes(output["stdout"]),
            bytes(output["stderr"]),
            int((time.monotonic() - started) * 1000),
        )
    finally:
        selector.close()
        if process.poll() is None:
            terminate_process_group(process, termination_grace_seconds)
        for _, stream, _ in streams.values():
            if not stream.closed:
                stream.close()


def decode_output(value: bytes, case_id: str, stream: str) -> str:
    try:
        return value.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise CheckFailure(f"{case_id} emitted non-UTF-8 {stream}") from error


def parse_json_output(stdout: str, case_id: str) -> dict[str, Any]:
    try:
        value = json.loads(stdout)
    except json.JSONDecodeError as error:
        raise CheckFailure(f"{case_id} did not emit one JSON document: {error}") from error
    require(isinstance(value, dict), f"{case_id} JSON must be an object")
    return value


def require_keys(value: dict[str, Any], keys: set[str], case_id: str) -> None:
    missing = sorted(keys - set(value))
    require(not missing, f"{case_id} JSON is missing keys: {', '.join(missing)}")


def validate_top_level_help(stdout: str, commands: list[str]) -> str:
    match = re.search(
        r"(?m)^Forge-Conductor ([0-9]+\.[0-9]+\.[0-9]+) — native Swift MCP orchestrator$",
        stdout,
    )
    require(match is not None, "top-level help header changed")
    require("Usage:\n  forge-conductor <command> [options]" in stdout, "top-level usage changed")
    for command in commands:
        require(
            re.search(rf"(?m)^\s+{re.escape(command)}(?:\s|$)", stdout) is not None,
            f"top-level help lost command: {command}",
        )
    return match.group(1)


def validate_manager_help(stdout: str, commands: list[str]) -> None:
    require(
        stdout.startswith("forge-conductor manager <subcommand>\n"),
        "manager help header changed",
    )
    for command in commands:
        require(
            re.search(rf"(?m)^\s+{re.escape(command)}(?:\s|$)", stdout) is not None,
            f"manager help lost subcommand: {command}",
        )


def canonical_help_text(stdout: str) -> str:
    return " ".join(stdout.replace("[", "").replace("]", "").split())


def validate_preserved_help_options(
    raw_results: dict[str, tuple[int, str, str]],
    preserved_options: dict[str, list[str]],
) -> list[dict[str, Any]]:
    require(
        set(preserved_options) == set(PRESERVED_OPTION_HELP_CASES),
        "preserved option help mapping is incomplete",
    )
    coverage: list[dict[str, Any]] = []
    missing: list[str] = []
    for group, arguments in preserved_options.items():
        help_cases = PRESERVED_OPTION_HELP_CASES[group]
        scope = group
        if group in TOP_LEVEL_OPTION_COMMANDS:
            command = TOP_LEVEL_OPTION_COMMANDS[group]
            match = re.search(
                rf"(?m)^\s+{re.escape(command)}(?=\s|$).*$",
                raw_results["no_arguments_help"][1],
            )
            require(match is not None, f"top-level help lost option scope: {command}")
            help_text = canonical_help_text(match.group(0))
            scope = f"top_level_command:{command}"
        else:
            help_text = " ".join(
                canonical_help_text(raw_results[case_id][1]) for case_id in help_cases
            )
        for argument in arguments:
            present = canonical_help_text(argument) in help_text
            coverage.append(
                {
                    "group": group,
                    "argument": argument,
                    "help_cases": list(help_cases),
                    "present": present,
                    "scope": scope,
                }
            )
            if not present:
                missing.append(f"{group}: {argument}")
    require(
        not missing,
        "current help omits baseline preserved options/arguments: " + "; ".join(missing),
    )
    return coverage


def validate_version(stdout: str, baseline_version: str) -> str:
    lines = stdout.splitlines()
    require(len(lines) == 1 and VERSION_PATTERN.fullmatch(lines[0]) is not None, "invalid version output")
    current = tuple(int(part) for part in lines[0].split("."))
    baseline = tuple(int(part) for part in baseline_version.split("."))
    require(current >= baseline, "CLI version regressed below the baseline")
    return lines[0]


def validate_case_output(
    case: dict[str, Any],
    stdout: str,
    stderr: str,
    exit_code: int,
    home: pathlib.Path,
    contract: dict[str, Any],
) -> str | None:
    case_id = case["id"]
    require(stderr == case["expected_stderr"], f"unexpected stderr for {case_id}")
    if "expected_stdout" in case:
        require(stdout == case["expected_stdout"], f"unexpected stdout for {case_id}")

    validator = case["validator"]
    version: str | None = None
    json_ok: bool | None = None
    if validator == "top_level_help":
        version = validate_top_level_help(stdout, contract["top_level_commands"])
    elif validator == "manager_help":
        validate_manager_help(stdout, contract["manager_subcommands"])
    elif validator == "version":
        version = validate_version(stdout, contract["baseline_version"])
    elif validator == "empty_stdout":
        require(stdout == "", f"{case_id} must not emit stdout")
    elif validator == "status_json":
        value = parse_json_output(stdout, case_id)
        require_keys(
            value,
            {
                "ok",
                "version",
                "product",
                "runtime",
                "home",
                "store",
                "agent_count",
                "tools",
                "manager_running",
            },
            case_id,
        )
        require(value["ok"] is True and value["runtime"] == "swift", "status health contract changed")
        require(value["home"] == str(home), "status escaped its isolated home")
        require(value["manager_running"] is False, "status found an unexpected isolated manager")
        require(isinstance(value["agent_count"], int) and value["agent_count"] >= 5, "status agent count is invalid")
        require(isinstance(value["tools"], list) and value["tools"], "status tool list is empty")
        require(isinstance(value["version"], str), "status version is invalid")
        version = value["version"]
    elif validator == "doctor_json":
        value = parse_json_output(stdout, case_id)
        require_keys(value, {"ok", "version", "home", "checks", "telemetry", "shell", "binary"}, case_id)
        require(isinstance(value["ok"], bool), "doctor ok must be boolean")
        require(value["home"] == str(home), "doctor escaped its isolated home")
        require(isinstance(value["checks"], list) and value["checks"], "doctor checks are empty")
        require(
            all(
                isinstance(item, dict)
                and isinstance(item.get("name"), str)
                and isinstance(item.get("ok"), bool)
                and isinstance(item.get("detail"), str)
                for item in value["checks"]
            ),
            "doctor checks have an invalid shape",
        )
        require(isinstance(value["version"], str), "doctor version is invalid")
        version = value["version"]
        json_ok = value["ok"]
    elif validator == "agents_tsv":
        rows = stdout.splitlines()
        require(len(rows) >= 5, "agents output lost baseline rows")
        columns = [row.split("\t") for row in rows]
        require(all(len(row) == 3 and all(part for part in row) for row in columns), "agents output is not three-column TSV")
        identifiers = [row[0] for row in columns]
        require(len(set(identifiers)) == len(identifiers), "agents output contains duplicate ids")
    elif validator == "manager_status_json":
        value = parse_json_output(stdout, case_id)
        require_keys(value, {"ok", "manager_running", "home", "dashboard"}, case_id)
        require(value["ok"] is True, "manager status is not healthy")
        require(value["manager_running"] is False, "manager status found an unexpected isolated manager")
        require(value["home"] == str(home), "manager status escaped its isolated home")
        dashboard = value["dashboard"]
        require(isinstance(dashboard, dict), "manager dashboard status is invalid")
        require(isinstance(dashboard.get("host"), str), "manager dashboard host is invalid")
        require(isinstance(dashboard.get("port"), int), "manager dashboard port is invalid")
    elif validator == "manager_stop_idle":
        require(stdout == "Manager is not running\n", "idle manager stop output changed")
    else:
        raise CheckFailure(f"unsupported validator: {validator}")

    expected_exit = case["expected_exit"]
    if expected_exit == "json_ok":
        require(json_ok is not None, f"{case_id} did not expose JSON health")
        expected_exit = 0 if json_ok else 1
    require(exit_code == expected_exit, f"{case_id} exited {exit_code}, expected {expected_exit}")
    return version


def child_environment(home: pathlib.Path, temporary: pathlib.Path) -> dict[str, str]:
    environment = dict(os.environ)
    for key in list(environment):
        if key.startswith("FORGE_"):
            environment.pop(key)
    environment["FORGE_CONDUCTOR_HOME"] = str(home)
    environment["FORGE_SKIP_PS"] = "1"
    environment["TMPDIR"] = str(temporary)
    return environment


def run_contract(
    binary: pathlib.Path,
    contract: dict[str, Any],
) -> tuple[list[dict[str, Any]], str, list[dict[str, Any]]]:
    limits = contract["limits"]
    raw_results: dict[str, tuple[int, str, str]] = {}
    summaries: list[dict[str, Any]] = []
    observed_versions: dict[str, str] = {}

    with tempfile.TemporaryDirectory(prefix="forge-p10-cli-") as temporary_root:
        temporary = pathlib.Path(temporary_root)
        for case in contract["runtime_cases"]:
            case_id = case["id"]
            case_root = temporary / case_id
            home = case_root / "home"
            child_tmp = case_root / "tmp"
            home.mkdir(parents=True)
            child_tmp.mkdir()
            arguments = [str(home) if item == "{home}" else item for item in case["arguments"]]
            command = [str(binary), *arguments]
            exit_code, stdout_bytes, stderr_bytes, duration_ms = run_bounded(
                command,
                child_environment(home, child_tmp),
                timeout_seconds=limits["case_timeout_seconds"],
                termination_grace_seconds=limits["termination_grace_seconds"],
                maximum_stdout_bytes=limits["maximum_stdout_bytes"],
                maximum_stderr_bytes=limits["maximum_stderr_bytes"],
            )
            stdout = decode_output(stdout_bytes, case_id, "stdout")
            stderr = decode_output(stderr_bytes, case_id, "stderr")
            version = validate_case_output(case, stdout, stderr, exit_code, home, contract)
            if version is not None:
                require(VERSION_PATTERN.fullmatch(version) is not None, f"invalid version in {case_id}")
                observed_versions[case_id] = version
            raw_results[case_id] = (exit_code, stdout, stderr)
            summaries.append(
                {
                    "id": case_id,
                    "arguments": case["arguments"],
                    "validator": case["validator"],
                    "exit_code": exit_code,
                    "duration_ms": duration_ms,
                    "stdout_bytes": len(stdout_bytes),
                    "stdout_sha256": hashlib.sha256(stdout_bytes).hexdigest(),
                    "stderr_bytes": len(stderr_bytes),
                    "stderr_sha256": hashlib.sha256(stderr_bytes).hexdigest(),
                }
            )

    for group in contract["equivalence_groups"]:
        values = [raw_results[case_id] for case_id in group["case_ids"]]
        require(all(value == values[0] for value in values[1:]), f"alias group diverged: {group['id']}")

    preserved_help_arguments = validate_preserved_help_options(
        raw_results,
        contract["preserved_options"],
    )

    require(
        raw_results["unknown_command"][1] == raw_results["no_arguments_help"][1],
        "unknown-command help differs from normal help",
    )
    current_version = observed_versions["version"]
    require(
        observed_versions["long_version"] == current_version,
        "version aliases disagree",
    )
    for case_id in ("no_arguments_help", "help", "short_help", "long_help", "unknown_command"):
        require(observed_versions[case_id] == current_version, f"help/version mismatch in {case_id}")
    for case_id in ("status", "doctor"):
        require(observed_versions[case_id] == current_version, f"JSON/version mismatch in {case_id}")
    return summaries, current_version, preserved_help_arguments


def atomic_write_json(
    path: pathlib.Path,
    value: dict[str, Any],
    *,
    protected: set[pathlib.Path],
) -> None:
    require(path.parent.is_dir(), f"report directory is missing: {path.parent}")
    require(path not in protected, "report path would overwrite a qualification input")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = pathlib.Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, help="forge-conductor executable to validate")
    parser.add_argument(
        "--baseline",
        default=str(DEFAULT_BASELINE),
        help="checked-in CLI compatibility contract",
    )
    parser.add_argument("--report", help="optional in-repository JSON report path")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    manifest_before = source_manifest(ROOT)
    baseline_path = resolve_repo_path(arguments.baseline)
    contract = load_contract(baseline_path)
    source_path = resolve_repo_path(contract["source_path"])
    require(source_path.is_file(), f"CLI source is missing: {source_path}")

    binary = pathlib.Path(arguments.binary)
    if not binary.is_absolute():
        binary = ROOT / binary
    binary = binary.resolve()
    require(binary.is_file(), f"CLI binary is missing: {binary}")
    require(os.access(binary, os.X_OK), f"CLI binary is not executable: {binary}")

    summaries, current_version, preserved_help_arguments = run_contract(binary, contract)
    manifest_after = source_manifest(ROOT)
    require(manifest_before == manifest_after, "source/test/checker manifest changed during the check")
    try:
        binary_display_path = binary.relative_to(ROOT).as_posix()
    except ValueError:
        binary_display_path = str(binary)
    report = {
        "schema_version": 2,
        "phase": "P10",
        "status": "passed",
        "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "source_manifest": manifest_before,
        "baseline_revision": contract["baseline_revision"],
        "baseline_version": contract["baseline_version"],
        "current_version": current_version,
        "hashes": {
            "binary_sha256": digest(binary),
            "source_sha256": digest(source_path),
            "baseline_sha256": digest(baseline_path),
        },
        "paths": {
            "binary": binary_display_path,
            "source": str(source_path.relative_to(ROOT)),
            "baseline": str(baseline_path.relative_to(ROOT)),
        },
        "limits": contract["limits"],
        "top_level_commands": contract["top_level_commands"],
        "manager_subcommands": contract["manager_subcommands"],
        "preserved_help_arguments": preserved_help_arguments,
        "runtime_cases": summaries,
        "runtime_case_count": len(summaries),
        "user_mutating_commands_executed": [],
    }
    if arguments.report:
        report_path = resolve_repo_path(arguments.report)
        atomic_write_json(
            report_path,
            report,
            protected={
                baseline_path,
                source_path,
                binary,
                pathlib.Path(__file__).resolve(),
            },
        )
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (CheckFailure, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
