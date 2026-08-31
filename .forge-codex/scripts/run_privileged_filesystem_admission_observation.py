#!/usr/bin/env python3
"""Record one bounded, non-mutating signed filesystem admission observation."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from typing import Any, Callable, Mapping

import run_privileged_filesystem_h0 as h0


SCRIPT_ROOT = pathlib.Path(__file__).resolve().parent
REPOSITORY_ROOT = SCRIPT_ROOT.parents[1]
SCHEMA_PATH = (
    REPOSITORY_ROOT
    / ".forge-codex/schemas/p10-privileged-filesystem-admission-observation.schema.json"
)
CLI_BARRIER_ENV = "FORGE_FILESYSTEM_QUALIFICATION_HEALTH_START_SUSPENDED"
ADVERSARY_BARRIER_ENV = h0.START_SUSPENDED_ENVIRONMENT_KEY
ADVERSARY_CONTEXT_ENV = "FORGE_FILESYSTEM_ADMISSION_PROBE_CONTEXT"
CLI_IDENTIFIER = "com.forge-conductor.cli"
ADVERSARY_IDENTIFIER = h0.ADVERSARY_IDENTIFIER
DAEMON_IDENTIFIER = "com.forge-conductor.filesystem-daemon"
SERVICE_IDENTIFIER = DAEMON_IDENTIFIER
MAXIMUM_LINE_BYTES = 16 * 1024
MAXIMUM_PROCESS_OUTPUT_BYTES = 32 * 1024
MAXIMUM_REPORT_BYTES = 1024 * 1024
MINIMUM_HOLD_MILLISECONDS = 3_000
MAXIMUM_HOLD_MILLISECONDS = 10_000
CLASSIFICATIONS = {
    "candidate_invalidation_observed",
    "adversary_admitted",
    "adversary_connection_error",
    "adversary_interrupted",
    "adversary_timeout",
    "authorized_daemon_unavailable",
    "authorized_daemon_restart_or_session_loss",
    "signature_or_executable_drift",
    "suspicious_adversary_exit",
    "inconclusive",
}
COMPLETION_KEYS = {"e2", "p10", "g10", "g12", "release"}
HEALTH_REQUIRED_KEYS = {
    "schema_version", "event", "session_id", "ok", "code", "message",
    "service_identity_verified", "connection_reused",
    "status_durability_confirmed", "hold_ms",
}
HEALTH_SERVICE_KEYS = {
    "protocol_version", "product_version", "service_identifier",
    "effective_uid", "code_directory_hash", "allowed_code_directory_hashes",
}
ADVERSARY_KEYS = {
    "schema_version", "operation", "run_id", "case_id", "role", "process_id",
    "effective_user_id", "bundle_identifier", "client_code_directory_hash",
    "daemon_code_directory_hashes", "daemon_signing_requirement_sha256",
    "deadline_milliseconds", "elapsed_monotonic_nanoseconds", "terminal_event",
    "outcome", "authorized_same_connection_control_observed",
    "daemon_reachability_confirmed", "unauthorized_client_rejection_confirmed",
    "production_mutation_exercised", "qualification_status", "rows_updated",
    "formal_predicates_updated", "completion_claims",
}


class ObservationError(RuntimeError):
    """A fail-closed admission observation error."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ObservationError(message)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def canonical_line(value: Mapping[str, Any]) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def strict_object(raw: bytes, label: str) -> dict[str, Any]:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ObservationError(f"{label} contains a duplicate key")
            result[key] = value
        return result

    try:
        decoded = raw.decode("utf-8")
        value = json.loads(decoded, object_pairs_hook=reject_duplicates)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ObservationError(f"{label} is not strict UTF-8 JSON") from error
    require(isinstance(value, dict), f"{label} is not an object")
    return value


def normalize_hashes(values: list[str]) -> list[str]:
    require(1 <= len(values) <= 2, "one or two daemon CDHashes are required")
    require(
        all(re.fullmatch(r"[0-9a-f]{40}", value) is not None for value in values),
        "daemon CDHashes must be canonical lowercase SHA-1-sized values",
    )
    normalized = sorted(set(values))
    require(normalized == values, "daemon CDHashes must be unique and sorted")
    return normalized


def daemon_requirement(hashes: list[str], expected_team: str, admission: Mapping[str, Any]) -> str:
    exact = " or ".join(f'cdhash H"{value}"' for value in hashes)
    designated = (
        f'anchor apple generic and identifier "{DAEMON_IDENTIFIER}" '
        f'and certificate leaf[subject.OU] = "{expected_team}" '
        f'and {admission["certificate_requirement"]}'
    )
    return f"({designated}) and ({exact})"


def validate_health(
    value: Mapping[str, Any], *, event: str, hold_ms: int, daemon_hashes: list[str]
) -> dict[str, Any]:
    keys = set(value)
    require(HEALTH_REQUIRED_KEYS <= keys, f"{event} health fields are incomplete")
    require(keys <= HEALTH_REQUIRED_KEYS | HEALTH_SERVICE_KEYS, f"{event} health has extra fields")
    require(type(value["schema_version"]) is int and value["schema_version"] == 1, "health schema changed")
    require(value["event"] == event, f"wrong {event} event")
    require(type(value["ok"]) is bool, f"{event} ok is not Boolean")
    require(type(value["hold_ms"]) is int and value["hold_ms"] == hold_ms, "hold changed")
    require(
        isinstance(value["session_id"], str)
        and re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", value["session_id"]),
        f"{event} session ID is invalid",
    )
    for key in ("code", "message"):
        require(isinstance(value[key], str) and value[key], f"{event} {key} is invalid")
    for key in ("service_identity_verified", "connection_reused", "status_durability_confirmed"):
        require(type(value[key]) is bool, f"{event} {key} is not Boolean")
    if value["ok"]:
        require(keys == HEALTH_REQUIRED_KEYS | HEALTH_SERVICE_KEYS, f"{event} success lacks service facts")
        require(value["code"] == "ok", f"{event} success code changed")
        require(value["service_identity_verified"] is True, f"{event} identity was not verified")
        require(value["status_durability_confirmed"] is True, f"{event} durability is absent")
        require(type(value["protocol_version"]) is int and value["protocol_version"] == 5, f"{event} protocol changed")
        require(value["product_version"] == "0.9.0", f"{event} product changed")
        require(value["service_identifier"] == SERVICE_IDENTIFIER, f"{event} service changed")
        require(type(value["effective_uid"]) is int and value["effective_uid"] == 0, f"{event} service is not root")
        require(value["code_directory_hash"] in daemon_hashes, f"{event} daemon hash is unbound")
        require(
            value["allowed_code_directory_hashes"] == daemon_hashes,
            f"{event} caller-sealed daemon hash set differs from recorder context",
        )
    return dict(value)


def validate_adversary(
    value: Mapping[str, Any], *, run_id: str, daemon_hashes: list[str],
    requirement_sha256: str, expected_cdhash: str, expected_pid: int,
    expected_effective_uid: int,
) -> dict[str, Any]:
    require(set(value) == ADVERSARY_KEYS, "adversary result fields changed")
    require(type(value["schema_version"]) is int and value["schema_version"] == 1, "adversary schema changed")
    require(value["operation"] == "admission-probe", "adversary operation changed")
    require(value["run_id"] == run_id, "adversary run ID changed")
    require(value["case_id"] == "unauthorized_same_uid_client", "adversary case changed")
    require(value["role"] == "adversary", "adversary role changed")
    require(type(value["process_id"]) is int and value["process_id"] == expected_pid, "adversary PID is not live-bound")
    require(
        type(value["effective_user_id"]) is int
        and value["effective_user_id"] == expected_effective_uid
        and expected_effective_uid > 0,
        "adversary effective UID is not recorder-bound",
    )
    require(value["bundle_identifier"] == ADVERSARY_IDENTIFIER, "adversary identifier changed")
    require(value["client_code_directory_hash"] == expected_cdhash, "adversary CDHash drifted")
    require(value["daemon_code_directory_hashes"] == daemon_hashes, "adversary daemon hashes changed")
    require(
        value["daemon_signing_requirement_sha256"] == requirement_sha256,
        "adversary daemon requirement changed",
    )
    require(value["deadline_milliseconds"] == 2_000, "adversary deadline changed")
    require(
        type(value["elapsed_monotonic_nanoseconds"]) is int
        and 0 <= value["elapsed_monotonic_nanoseconds"] <= 2_000_000_000,
        "adversary elapsed time is invalid",
    )
    require(value["production_mutation_exercised"] is False, "adversary claimed mutation")
    require(value["rows_updated"] == 0 and value["formal_predicates_updated"] == 0, "qualification advanced")
    require(
        isinstance(value["completion_claims"], dict)
        and set(value["completion_claims"]) == COMPLETION_KEYS
        and all(item is False for item in value["completion_claims"].values()),
        "adversary claimed completion",
    )
    for key in (
        "authorized_same_connection_control_observed", "daemon_reachability_confirmed",
        "unauthorized_client_rejection_confirmed",
    ):
        require(value[key] is False, f"adversary prematurely set {key}")
    expected_combination = {
        "service_info_reply": ("unexpected_admission", "failed"),
        "connection_error": ("candidate_connection_rejected_pending_authorized_control", "candidate_only"),
        "connection_interrupted": ("candidate_connection_rejected_pending_authorized_control", "candidate_only"),
        "connection_invalidated": ("candidate_connection_rejected_pending_authorized_control", "candidate_only"),
        "deadline_expired": ("ambiguous_timeout", "ambiguous"),
    }
    require(value["terminal_event"] in expected_combination, "adversary terminal event changed")
    require(
        (value["outcome"], value["qualification_status"])
        == expected_combination[value["terminal_event"]],
        "adversary event, outcome, and status are inconsistent",
    )
    return dict(value)


def classify_adversary(value: Mapping[str, Any], return_code: int) -> str:
    event = value["terminal_event"]
    outcome = value["outcome"]
    if return_code == 0:
        return "suspicious_adversary_exit"
    if event == "connection_invalidated" and outcome == "candidate_connection_rejected_pending_authorized_control":
        return "candidate_invalidation_observed"
    if event == "service_info_reply" or outcome == "unexpected_admission":
        return "adversary_admitted"
    if event == "connection_error":
        return "adversary_connection_error"
    if event == "connection_interrupted":
        return "adversary_interrupted"
    if event == "deadline_expired" or outcome == "ambiguous_timeout":
        return "adversary_timeout"
    return "inconclusive"


def validate_pair(pre: Mapping[str, Any], post: Mapping[str, Any], daemon_hashes: list[str]) -> dict[str, bool]:
    same_session = pre["session_id"] == post["session_id"]
    reused = pre["connection_reused"] is False and post["connection_reused"] is True
    same_hash = pre.get("code_directory_hash") == post.get("code_directory_hash")
    hash_bound = pre.get("code_directory_hash") in daemon_hashes and post.get("code_directory_hash") in daemon_hashes
    stable = all(
        pre.get(key) == post.get(key)
        for key in ("protocol_version", "product_version", "service_identifier", "effective_uid")
    )
    return {
        "same_session_id": same_session,
        "connection_reused": reused,
        "daemon_code_directory_hash_equal": same_hash,
        "daemon_hash_in_exact_context": hash_bound,
        "caller_sealed_hash_set_equal": (
            pre.get("allowed_code_directory_hashes") == daemon_hashes
            and post.get("allowed_code_directory_hashes") == daemon_hashes
        ),
        "service_facts_stable": stable,
    }


def wait_live_cdhash(process: subprocess.Popen[bytes], expected: str, timeout: float) -> str:
    deadline = time.monotonic() + timeout
    last: Exception | None = None
    while time.monotonic() < deadline:
        if process.poll() is not None:
            break
        try:
            value = h0.live_process_cdhash(process.pid)
            require(value == expected, "live process CDHash differs from signed executable")
            return value
        except (h0.H0Error, ObservationError) as error:
            last = error
            time.sleep(0.005)
    raise ObservationError(f"cannot bind live process identity: {last}")


def wait_json_line(
    descriptor: int, *, offset: int, deadline: float, process: subprocess.Popen[bytes], label: str,
) -> tuple[dict[str, Any], int, bytes]:
    buffer = bytearray()
    while time.monotonic() < deadline:
        block = os.pread(descriptor, MAXIMUM_LINE_BYTES - len(buffer) + 1, offset + len(buffer))
        if block:
            buffer.extend(block)
            require(len(buffer) <= MAXIMUM_LINE_BYTES, f"{label} exceeds line bound")
            newline = buffer.find(b"\n")
            if newline >= 0:
                raw = bytes(buffer[: newline + 1])
                require(newline == len(buffer) - 1, f"{label} emitted more than one pending line")
                value = strict_object(raw, label)
                require(raw == canonical_line(value), f"{label} is not canonical JSON")
                return value, offset + len(raw), raw
        elif process.poll() is not None:
            break
        time.sleep(0.01)
    raise ObservationError(f"{label} was not produced before its deadline")


def signature_summary(
    path: pathlib.Path, *, identifier: str, expected_team: str,
    admission: Mapping[str, Any], daemon_client_expected: bool, timeout: float,
) -> dict[str, Any]:
    before = h0.snapshot_regular_file(
        path, label="signed admission executable", maximum_bytes=h0.MAXIMUM_EXECUTABLE_BYTES,
        executable=True,
    )
    own = (
        f'anchor apple generic and identifier "{identifier}" '
        f'and certificate leaf[subject.OU] = "{expected_team}" '
        f'and {admission["certificate_requirement"]}'
    )
    for label, arguments in (
        ("signature", ["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", "--verbose=4", str(path)]),
        ("exact identity", ["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", "--verbose=4", f"-R={own}", str(path)]),
    ):
        result = h0.run_bounded(arguments, timeout=timeout)
        require(not result.timed_out and result.returncode == 0, f"{label} validation failed for {path}")
    displayed = h0.run_bounded(["/usr/bin/codesign", "--display", "--verbose=4", str(path)], timeout=timeout)
    require(displayed.returncode == 0 and not displayed.timed_out, "cannot inspect signature")
    details = h0.parse_codesign_details((displayed.stdout + displayed.stderr).decode("utf-8", "replace"))
    require(details["identifier"] == identifier, "signed identifier differs")
    require(details["team_identifier"] == expected_team, "signed team differs")
    require("runtime" in details["code_directory"], "hardened runtime is absent")
    daemon_check = h0.run_bounded(
        ["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", "--verbose=4", f"-R={admission['requirement']}", str(path)],
        timeout=timeout,
    )
    require(not daemon_check.timed_out, "daemon client requirement check timed out")
    satisfied = daemon_check.returncode == 0
    require(satisfied is daemon_client_expected, "daemon client requirement result differs")
    after = h0.snapshot_regular_file(
        path, label="signed admission executable", maximum_bytes=h0.MAXIMUM_EXECUTABLE_BYTES,
        executable=True,
    )
    h0.require_unchanged(before, after, "signed admission executable")
    return {
        "path": str(path), "sha256": before.sha256, "size": before.size,
        "device": before.device, "inode": before.inode, "change_time_ns": before.change_time_ns,
        "identifier": identifier, "team_identifier": expected_team,
        "code_directory_hash": details["cdhash"], "hardened_runtime": True,
        "exact_identity_requirement_satisfied": True,
        "daemon_client_requirement_satisfied": satisfied,
    }


def command_record(label: str, result: h0.BoundedCommandResult, live_cdhash: str) -> dict[str, Any]:
    return {
        "label": label, "arguments": list(result.arguments), "process_id": result.pid,
        "return_code": result.returncode, "timed_out": result.timed_out,
        "stdout_bytes": len(result.stdout), "stderr_bytes": len(result.stderr),
        "stdout_sha256": sha256_bytes(result.stdout), "stderr_sha256": sha256_bytes(result.stderr),
        "process_group_cleanup": result.process_group_cleanup, "live_code_directory_hash": live_cdhash,
    }


def run_adversary(
    path: pathlib.Path, *, signature: Mapping[str, Any], run_id: str,
    daemon_hashes: list[str], requirement_sha256: str, timeout: float,
) -> tuple[dict[str, Any], dict[str, Any], str]:
    context = {
        "schema_version": 1, "run_id": run_id, "operation": "admission-probe",
        "role": "adversary", "case_id": "unauthorized_same_uid_client",
        "daemon_code_directory_hashes": daemon_hashes,
    }
    environment = {
        ADVERSARY_BARRIER_ENV: "1",
        ADVERSARY_CONTEXT_ENV: json.dumps(context, sort_keys=True, separators=(",", ":")),
    }
    live: dict[str, str] = {}

    def bind(process: subprocess.Popen[bytes]) -> None:
        h0.wait_for_suspended_child(process, min(timeout, 2.0))
        value = h0.live_process_cdhash(process.pid)
        require(value == signature["code_directory_hash"], "live adversary CDHash drifted")
        live["cdhash"] = value
        h0._signal_process_group(process.pid, signal.SIGCONT)

    result = h0.run_bounded(
        [str(path), "admission-probe"], timeout=timeout,
        maximum_output_bytes=MAXIMUM_PROCESS_OUTPUT_BYTES, environment=environment,
        on_started=bind,
    )
    require(not result.timed_out, "adversary process exceeded its outer deadline")
    require(result.stderr == b"", "adversary emitted diagnostics")
    value = strict_object(result.stdout, "adversary result")
    require(result.stdout == canonical_line(value), "adversary output is not one canonical line")
    parsed = validate_adversary(
        value, run_id=run_id, daemon_hashes=daemon_hashes,
        requirement_sha256=requirement_sha256,
        expected_cdhash=str(signature["code_directory_hash"]), expected_pid=result.pid,
        expected_effective_uid=os.geteuid(),
    )
    return parsed, command_record("signed_wrong_identifier_admission_probe", result, live["cdhash"]), classify_adversary(parsed, result.returncode)


def run_held_pair(
    cli: pathlib.Path, adversary: pathlib.Path, *, cli_signature: Mapping[str, Any],
    adversary_signature: Mapping[str, Any], run_id: str, daemon_hashes: list[str],
    requirement_sha256: str, hold_ms: int, timeout: float,
) -> dict[str, Any]:
    require(MINIMUM_HOLD_MILLISECONDS <= hold_ms <= MAXIMUM_HOLD_MILLISECONDS, "hold is outside bounds")
    deadline = time.monotonic() + timeout
    process: subprocess.Popen[bytes] | None = None
    cleanup = "not_started"
    with tempfile.TemporaryDirectory(prefix="forge-filesystem-admission-") as temporary:
        root = pathlib.Path(temporary)
        stdout_path, stderr_path = root / "stdout", root / "stderr"
        with stdout_path.open("w+b") as stdout_stream, stderr_path.open("w+b") as stderr_stream:
            try:
                process = subprocess.Popen(
                    [str(cli), "qualification-filesystem-health", "--hold-ms", str(hold_ms)],
                    stdin=subprocess.DEVNULL, stdout=stdout_stream, stderr=stderr_stream,
                    env=h0.minimal_environment({CLI_BARRIER_ENV: "1"}), close_fds=True,
                    start_new_session=True,
                    preexec_fn=lambda: h0._child_limits(MAXIMUM_PROCESS_OUTPUT_BYTES, timeout),
                )
                h0.wait_for_suspended_child(process, min(timeout, 2.0))
                cli_live = h0.live_process_cdhash(process.pid)
                require(cli_live == cli_signature["code_directory_hash"], "live CLI CDHash drifted")
                h0._signal_process_group(process.pid, signal.SIGCONT)
                read_fd = os.open(stdout_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
                try:
                    pre_raw, offset, pre_bytes = wait_json_line(
                        read_fd, offset=0, deadline=deadline, process=process, label="authorized pre-health",
                    )
                    pre = validate_health(pre_raw, event="pre_health", hold_ms=hold_ms, daemon_hashes=daemon_hashes)
                    if not pre["ok"]:
                        classification = "authorized_daemon_unavailable"
                        adversary_result = None
                        adversary_command = None
                        post = None
                        correlation = {
                            "same_session_id": False, "connection_reused": False,
                            "daemon_code_directory_hash_equal": False,
                            "daemon_hash_in_exact_context": False,
                            "caller_sealed_hash_set_equal": False,
                            "service_facts_stable": False,
                        }
                    else:
                        remaining = deadline - time.monotonic()
                        require(remaining > 2.0, "no bounded time remains for adversary")
                        adversary_result, adversary_command, classification = run_adversary(
                            adversary, signature=adversary_signature, run_id=run_id,
                            daemon_hashes=daemon_hashes, requirement_sha256=requirement_sha256,
                            timeout=min(4.0, remaining),
                        )
                        post_raw, offset, post_bytes = wait_json_line(
                            read_fd, offset=offset, deadline=deadline, process=process,
                            label="authorized post-health",
                        )
                        post = validate_health(post_raw, event="post_health", hold_ms=hold_ms, daemon_hashes=daemon_hashes)
                        correlation = validate_pair(pre, post, daemon_hashes)
                        if not post["ok"] or not all(correlation.values()):
                            classification = "authorized_daemon_restart_or_session_loss"
                    remaining = max(0.01, deadline - time.monotonic())
                    try:
                        process.wait(timeout=remaining)
                    except subprocess.TimeoutExpired as error:
                        raise ObservationError("authorized held process exceeded total deadline") from error
                finally:
                    os.close(read_fd)
            finally:
                if process is not None:
                    cleanup = h0._cleanup_process_group(process)
            stdout_stream.flush(); stderr_stream.flush()
            stdout = stdout_path.read_bytes(); stderr = stderr_path.read_bytes()
    require(process is not None and process.returncode is not None, "authorized process has no status")
    require(len(stdout) + len(stderr) <= MAXIMUM_PROCESS_OUTPUT_BYTES * 2, "authorized output exceeded bounds")
    require(stderr == b"", "authorized process emitted diagnostics")
    if pre["ok"]:
        require(process.returncode == 0, "authorized held process failed")
        require(stdout == pre_bytes + post_bytes, "authorized output contains extra lines")
    return {
        "classification": classification,
        "pre": pre, "adversary": adversary_result, "post": post,
        "correlation": correlation,
        "commands": [
            {
                "label": "signed_authorized_same_connection_health", "arguments": [
                    str(cli), "qualification-filesystem-health", "--hold-ms", str(hold_ms)
                ], "process_id": process.pid, "return_code": process.returncode,
                "timed_out": False, "stdout_bytes": len(stdout), "stderr_bytes": len(stderr),
                "stdout_sha256": sha256_bytes(stdout), "stderr_sha256": sha256_bytes(stderr),
                "process_group_cleanup": cleanup, "live_code_directory_hash": cli_live,
            }
        ] + ([adversary_command] if adversary_command else []),
    }


def initial_report(args: argparse.Namespace) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "kind": "p10-privileged-filesystem-admission-observation",
        "generated_at": h0.utc_now(), "run_id": str(uuid.uuid4()),
        "overall_status": "blocked", "classification": "inconclusive",
        "production_mutation_exercised": False, "qualification_status": "not_run",
        "rows_updated": 0, "formal_predicates_updated": 0,
        "caller_identity_rejection_status": "pending_full_signed_paired_control_interpretation",
        "matrix": {"required_rows": 57, "executed_rows": 0},
        "formal_closure": {"required_predicates": 12, "proven_predicates": 0},
        "completion_claims": h0.false_completion_claims(),
        "repository": None, "source_manifest": None, "recorder_evidence_context": None,
        "canonical_qualification_template": None,
        "inputs": {
            "cli_path": str(args.cli), "adversary_path": str(args.adversary),
            "expected_team": args.expected_team, "daemon_code_directory_hashes": list(args.daemon_cdhash),
            "hold_milliseconds": args.hold_ms, "total_deadline_seconds": args.command_timeout,
            "daemon_signing_requirement_sha256": None,
        },
        "signatures": {"cli": None, "adversary": None},
        "observations": {"authorized_pre_health": None, "adversary": None, "authorized_post_health": None},
        "correlation": {
            "same_session_id": False, "connection_reused": False,
            "daemon_code_directory_hash_equal": False,
            "daemon_hash_in_exact_context": False,
            "caller_sealed_hash_set_equal": False,
            "service_facts_stable": False,
        },
        "commands": [], "blocking_reasons": [],
        "release_blockers": [
            "This observation does not execute or update any E2 matrix row or formal predicate.",
            "Caller-identity rejection remains pending full signed paired-control interpretation.",
            "E2, P10, G10, G12, native signing and UI, continuity, hardware, and release qualification remain open.",
        ],
    }


def validate_schema(report: Mapping[str, Any]) -> None:
    try:
        from jsonschema import Draft202012Validator
        schema = strict_object(SCHEMA_PATH.read_bytes(), "admission observation schema")
        Draft202012Validator.check_schema(schema)
        errors = sorted(Draft202012Validator(schema).iter_errors(dict(report)), key=lambda e: list(e.absolute_path))
    except ImportError as error:
        raise ObservationError("jsonschema is unavailable") from error
    if errors:
        error = errors[0]
        raise ObservationError(f"report schema error at {list(error.absolute_path)}: {error.message}")
    require(report["classification"] in CLASSIFICATIONS, "unknown report classification")
    require(all(value is False for value in report["completion_claims"].values()), "report claimed completion")
    if report["overall_status"] == "observed":
        require(report["classification"] == "candidate_invalidation_observed", "observed status has wrong classification")
        require(report["blocking_reasons"] == [], "observed report has blocking reasons")
        for key in (
            "repository", "source_manifest", "recorder_evidence_context",
            "canonical_qualification_template",
        ):
            require(report[key] is not None, f"observed report lacks {key}")
        require(
            report["inputs"]["daemon_signing_requirement_sha256"] is not None,
            "observed report lacks exact daemon requirement binding",
        )
        require(all(report["signatures"].values()), "observed report lacks signatures")
        observations = report["observations"]
        require(all(observations.values()), "observed report lacks paired observations")
        require(observations["authorized_pre_health"]["ok"] is True, "observed pre-health failed")
        require(observations["authorized_post_health"]["ok"] is True, "observed post-health failed")
        require(
            observations["adversary"]["terminal_event"] == "connection_invalidated",
            "observed report lacks explicit pre-reply invalidation",
        )
        require(
            observations["adversary"]["outcome"]
            == "candidate_connection_rejected_pending_authorized_control"
            and observations["adversary"]["qualification_status"] == "candidate_only",
            "observed adversary interpretation changed",
        )
        require(all(report["correlation"].values()), "observed report lacks exact correlation")
        require(len(report["commands"]) == 2, "observed report lacks both signed commands")
        require(
            [item["label"] for item in report["commands"]]
            == [
                "signed_authorized_same_connection_health",
                "signed_wrong_identifier_admission_probe",
            ],
            "observed report command inventory changed",
        )
        repository = report["repository"]
        recorder = report["recorder_evidence_context"]
        require(report["source_manifest"] == recorder["source_manifest"], "observed source manifests differ")
        require(
            recorder["repository"] == {
                "branch": repository["branch"], "head_sha": repository["head"],
                "base_branch": repository["base_branch"], "base_sha": repository["base_sha"],
                "repository_path": repository["path"],
            },
            "observed repository and recorder identities differ",
        )
        hashes = report["inputs"]["daemon_code_directory_hashes"]
        adversary = observations["adversary"]
        require(adversary["run_id"] == report["run_id"], "observed run IDs differ")
        require(adversary["daemon_code_directory_hashes"] == hashes, "observed adversary hash set differs")
        require(
            observations["authorized_pre_health"]["allowed_code_directory_hashes"] == hashes
            and observations["authorized_post_health"]["allowed_code_directory_hashes"] == hashes,
            "observed caller-sealed hash set differs",
        )
        require(
            adversary["daemon_signing_requirement_sha256"]
            == report["inputs"]["daemon_signing_requirement_sha256"],
            "observed daemon requirements differ",
        )
        signatures = report["signatures"]
        authorized_command, adversary_command = report["commands"]
        require(
            signatures["cli"]["identifier"] == CLI_IDENTIFIER
            and signatures["adversary"]["identifier"] == ADVERSARY_IDENTIFIER
            and signatures["cli"]["team_identifier"] == report["inputs"]["expected_team"]
            and signatures["adversary"]["team_identifier"] == report["inputs"]["expected_team"],
            "observed signing identifiers differ",
        )
        require(
            signatures["cli"]["daemon_client_requirement_satisfied"] is True
            and signatures["adversary"]["daemon_client_requirement_satisfied"] is False,
            "observed daemon client admission identities differ",
        )
        require(signatures["cli"]["path"] == report["inputs"]["cli_path"], "observed CLI paths differ")
        require(signatures["adversary"]["path"] == report["inputs"]["adversary_path"], "observed adversary paths differ")
        require(
            authorized_command["live_code_directory_hash"] == signatures["cli"]["code_directory_hash"]
            and adversary_command["live_code_directory_hash"] == signatures["adversary"]["code_directory_hash"]
            and adversary["client_code_directory_hash"] == signatures["adversary"]["code_directory_hash"],
            "observed live and static process identities differ",
        )
        require(adversary_command["process_id"] == adversary["process_id"], "observed adversary PIDs differ")
        require(
            authorized_command["return_code"] == 0
            and authorized_command["stderr_bytes"] == 0
            and adversary_command["stderr_bytes"] == 0,
            "observed command terminal facts differ",
        )
        require(
            authorized_command["stdout_sha256"]
            == sha256_bytes(
                canonical_line(observations["authorized_pre_health"])
                + canonical_line(observations["authorized_post_health"])
            )
            and adversary_command["stdout_sha256"] == sha256_bytes(canonical_line(adversary)),
            "observed command output digests differ",
        )
        adversary_commands = [item for item in report["commands"] if item["label"] == "signed_wrong_identifier_admission_probe"]
        require(len(adversary_commands) == 1 and adversary_commands[0]["return_code"] != 0, "observed report accepted suspicious adversary exit")


def emit(report: Mapping[str, Any], output: pathlib.Path) -> None:
    validate_schema(report)
    encoded = (json.dumps(report, indent=2, sort_keys=True) + "\n").encode()
    require(len(encoded) <= MAXIMUM_REPORT_BYTES, "report exceeds bound")
    require(output.is_absolute(), "output must be absolute")
    output.parent.mkdir(parents=True, exist_ok=True)
    require(not output.is_symlink(), "output must not be a symlink")
    descriptor, name = tempfile.mkstemp(prefix=f".{output.name}.", dir=output.parent)
    temporary = pathlib.Path(name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(encoded); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, output)
    finally:
        if temporary.exists(): temporary.unlink()
    sys.stdout.buffer.write(encoded)


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Record a non-mutating signed admission observation; never advance E2 qualification.")
    parser.add_argument("--cli", required=True, type=pathlib.Path)
    parser.add_argument("--adversary", required=True, type=pathlib.Path)
    parser.add_argument("--expected-team", required=True)
    parser.add_argument("--daemon-cdhash", action="append", required=True)
    parser.add_argument("--hold-ms", type=int, default=5_000)
    parser.add_argument("--command-timeout", type=float, default=18.0)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--execute", action="store_true", required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        output_path = h0.validate_output_path(
            args.output,
            protected_paths=[args.cli, args.adversary, SCHEMA_PATH, h0.PROTOCOL_SOURCE],
        )
    except (h0.H0Error, OSError) as error:
        sys.stderr.write(f"admission observation output rejected: {error}\n")
        return 2
    report = initial_report(args)
    exit_code = 2
    try:
        require(5.0 <= args.command_timeout <= 30.0, "total deadline is outside bounds")
        hashes = normalize_hashes(list(args.daemon_cdhash))
        h0.validate_logged_in_user()
        repository = h0.repository_identity(min(args.command_timeout, 10.0))
        recorder = h0.validate_recorder_evidence_context(os.environ, required=True, repository=repository)
        template_before, template_facts = h0.validate_nonpassing_qualification_template(h0.QUALIFICATION_TEMPLATE)
        paths = h0.validate_executable_paths(args.cli, args.adversary)
        cli, adversary = paths["harness"], paths["adversary"]
        admission = h0.read_daemon_client_requirement(h0.PROTOCOL_SOURCE, args.expected_team)
        requirement = daemon_requirement(hashes, args.expected_team, admission)
        requirement_sha256 = sha256_bytes(requirement.encode())
        cli_signature = signature_summary(
            cli, identifier=CLI_IDENTIFIER, expected_team=args.expected_team,
            admission=admission, daemon_client_expected=True, timeout=min(args.command_timeout, 10.0),
        )
        adversary_signature = signature_summary(
            adversary, identifier=ADVERSARY_IDENTIFIER, expected_team=args.expected_team,
            admission=admission, daemon_client_expected=False, timeout=min(args.command_timeout, 10.0),
        )
        result = run_held_pair(
            cli, adversary, cli_signature=cli_signature, adversary_signature=adversary_signature,
            run_id=report["run_id"], daemon_hashes=hashes,
            requirement_sha256=requirement_sha256, hold_ms=args.hold_ms,
            timeout=args.command_timeout,
        )
        template_after, _ = h0.validate_nonpassing_qualification_template(h0.QUALIFICATION_TEMPLATE)
        h0.require_unchanged(template_before, template_after, "canonical qualification template")
        report.update({
            "overall_status": "observed" if result["classification"] == "candidate_invalidation_observed" else "blocked",
            "classification": result["classification"], "repository": repository,
            "source_manifest": recorder["source_manifest"], "recorder_evidence_context": recorder,
            "canonical_qualification_template": {
                **template_facts, "before_sha256": template_before.sha256,
                "after_sha256": template_after.sha256, "byte_stable": True,
            },
            "signatures": {"cli": cli_signature, "adversary": adversary_signature},
            "observations": {
                "authorized_pre_health": result["pre"], "adversary": result["adversary"],
                "authorized_post_health": result["post"],
            },
            "correlation": result["correlation"], "commands": result["commands"],
        })
        report["inputs"].update({
            "cli_path": str(cli), "adversary_path": str(adversary),
            "daemon_code_directory_hashes": hashes,
            "daemon_signing_requirement_sha256": requirement_sha256,
        })
        if report["overall_status"] == "blocked":
            report["blocking_reasons"].append(f"admission observation is {report['classification']}")
        exit_code = 0 if report["overall_status"] == "observed" else 2
    except (ObservationError, h0.H0Error, OSError, ValueError) as error:
        message = str(error)
        report["classification"] = (
            "signature_or_executable_drift"
            if any(token in message.lower() for token in ("signature", "cdhash", "executable", "identity"))
            else "inconclusive"
        )
        report["blocking_reasons"].append(message[:2048])
    emit(report, output_path)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
