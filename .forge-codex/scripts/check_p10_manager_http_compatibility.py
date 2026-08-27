#!/usr/bin/env python3
"""Validate the preserved manager HTTP contract with a bounded loopback probe."""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import pathlib
import re
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

from evidence_support import atomic_write_json, source_manifest


ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_BASELINE = ROOT / ".forge-codex/state/baseline/manager-http-contract.json"
DEFAULT_BINARY = ROOT / ".build/release/forge-conductor"

EXPECTED_BASELINE_SHA256 = "0ca282a25abe7e839d15e56d93673161c80961a4fcc79110171d05016e0dcf5c"
EXPECTED_BASELINE_REVISION = "1fce9e0188698167564056ee8ace266342f97c7b"
EXPECTED_BASELINE_SOURCE_AGGREGATE_SHA256 = (
    "9741829234df2a61c6d84cd9eb8ed02c8afaf322ced46ebd79110c9389d8523d"
)
EXPECTED_BASELINE_SOURCE_SHA256 = {
    "Sources/ForgeConductorCore/Dashboard/DashboardHTTPRequest.swift":
        "c77b002f3c1e0ae390e7a32e3ff5101d37a60816260783c736b277493692d391",
    "Sources/ForgeConductorCore/Dashboard/DashboardServer.swift":
        "71c69533bb32573667575e3c3f83ec0adc6aaa2a1f81fcd6e20000a32aae7f32",
    "Sources/ForgeConductorCore/Dashboard/HTTPResponder.swift":
        "0bbfe8a88ec557f9d4324cc12bbf3763491d0edb88a33eba781c5ed2e968cfe1",
    "Sources/ForgeConductorCore/Dashboard/ManagerRoutes.swift":
        "4ed02b2a804bbd9255daa6e780655a732139ea2bfbe07d4285e125e6390e7ce4",
    "Sources/ForgeConductorCore/Domain/ManagerModels.swift":
        "047f31db9e7ef9d721aac8081dc16c52ae2454044866e87a85cc791fde70e4e0",
    "Sources/ForgeConductorCore/Infrastructure/AppPaths.swift":
        "dbae2ee6b38ccc019d46d9406952c7a8430cd88587c9640b5479d033de4b4af9",
    "Sources/ForgeConductorCore/Manager/ManagerNode.swift":
        "a734bc2b50ce50126d7fb2562ef0fc56586db28c65ff67514796d3c840a81f1f",
}

EXPECTED_BASELINE_ROUTES = [
    ["GET", "/api/manager/status"],
    ["GET", "/api/manager/settings"],
    ["POST", "/api/manager/start"],
    ["POST", "/api/manager/stop"],
    ["POST", "/api/manager/restart"],
    ["POST", "/api/manager/shutdown"],
    ["POST", "/api/manager/settings"],
    ["PUT", "/api/manager/settings"],
]

EXPECTED_ROUTE_SPECS = [
    {
        "method": "GET", "path": "/api/manager/status", "success_status": 200,
        "authorization": "public", "safe_probe": "success",
    },
    {
        "method": "GET", "path": "/api/manager/settings", "success_status": 200,
        "authorization": "public", "safe_probe": "success",
    },
    {
        "method": "GET", "path": "/api/manager/operator/snapshot", "success_status": 200,
        "authorization": "public", "safe_probe": "success",
    },
    {
        "method": "POST", "path": "/api/manager/start", "success_status": 200,
        "authorization": "bearer", "safe_probe": "authenticated_success_temporary_home",
    },
    {
        "method": "POST", "path": "/api/manager/stop", "success_status": 200,
        "authorization": "bearer", "safe_probe": "authenticated_success_temporary_home",
    },
    {
        "method": "POST", "path": "/api/manager/restart", "success_status": 200,
        "authorization": "bearer", "safe_probe": "authenticated_success_temporary_home",
    },
    {
        "method": "POST", "path": "/api/manager/shutdown", "success_status": 200,
        "authorization": "bearer", "safe_probe": "authenticated_success_temporary_home_shutdown",
    },
    {
        "method": "POST", "path": "/api/manager/settings", "success_status": 200,
        "authorization": "bearer", "safe_probe": "authenticated_success_temporary_home",
    },
    {
        "method": "PUT", "path": "/api/manager/settings", "success_status": 200,
        "authorization": "bearer", "safe_probe": "authenticated_success_temporary_home",
    },
    {
        "method": "POST", "path": "/api/manager/projects/register", "success_status": 200,
        "authorization": "bearer", "safe_probe": "authenticated_success_temporary_project",
    },
    {
        "method": "POST", "path": "/api/manager/projects/status", "success_status": 200,
        "authorization": "public", "safe_probe": "authenticated_success_temporary_project",
    },
    {
        "method": "POST", "path": "/api/manager/projects/bind", "success_status": 200,
        "authorization": "bearer", "safe_probe": "authenticated_success_temporary_project",
    },
    {
        "method": "POST", "path": "/api/manager/projects/reset-generation", "success_status": 200,
        "authorization": "bearer", "safe_probe": "authenticated_success_temporary_project",
    },
    {
        "method": "GET", "path": "/api/manager/autonomy/status", "success_status": 200,
        "authorization": "public", "safe_probe": "success",
    },
    {
        "method": "POST", "path": "/api/manager/runs/start", "success_status": 202,
        "authorization": "bearer", "safe_probe": "unauthorized_401_success_uncovered",
    },
    {
        "method": "POST", "path": "/api/manager/runs/status", "success_status": 200,
        "authorization": "public", "safe_probe": "invalid_request_500_success_uncovered",
    },
    {
        "method": "POST", "path": "/api/manager/runs/control", "success_status": 200,
        "authorization": "bearer", "safe_probe": "authenticated_invalid_400_success_uncovered",
    },
]

RUN_FIXTURE_ID = "01234567-89ab-4cde-8fab-0123456789ab"
RUN_FIXTURE_PROVIDER_ID = "p10.fixture.provider"
RUN_FIXTURE_ADAPTER_ID = "p10.fixture.unregistered-adapter"
RUN_FIXTURE_MODEL_KEY = "p10-fixture-model"
RUN_FIXTURE_INITIAL_STATE = "created"
RUN_FIXTURE_INITIAL_REVISION = 0
RUN_FIXTURE_CAUSAL_STATE = "waiting_provider"
RUN_FIXTURE_CAUSAL_REVISION = 6
RUN_FIXTURE_CAUSAL_ERROR_CODE = "run_step_failed"
RUN_FIXTURE_CAUSAL_ERROR_SUMMARY = "Host cannot create and bootstrap a successor session"
RUN_FIXTURE_CAUSAL_EVENT_KIND = "autonomous_run_waiting_provider"
RUN_FIXTURE_CAUSAL_EVENT_SUMMARY = "Run yielded after a transient execution failure"
RUN_FIXTURE_PROGRESS_REVISIONS = {
    "created": {0},
    "validating": {1},
    "ready": {2},
    "starting": {3},
    "running": {4, 5},
    "waiting_provider": {6},
}
RUN_FIXTURE_EVENT_KINDS_NEWEST_FIRST = [
    "autonomous_run_waiting_provider",
    "run_side_effect_intent_persisted",
    "autonomous_run_running",
    "autonomous_run_starting",
    "autonomous_run_ready",
    "autonomous_run_validation_started",
    "run_lease_acquired",
    "autonomous_run_created",
]

EXPECTED_DIRECT_STATUSES = {
    ("GET", "/api/manager/status"): {200},
    ("GET", "/api/manager/settings"): {200},
    ("GET", "/api/manager/operator/snapshot"): {200, 400},
    ("POST", "/api/manager/start"): {200},
    ("POST", "/api/manager/stop"): {200},
    ("POST", "/api/manager/restart"): {200},
    ("POST", "/api/manager/shutdown"): {200},
    ("POST", "/api/manager/settings"): {200},
    ("PUT", "/api/manager/settings"): {200},
    ("POST", "/api/manager/projects/register"): {200},
    ("POST", "/api/manager/projects/status"): {200},
    ("POST", "/api/manager/projects/bind"): {200},
    ("POST", "/api/manager/projects/reset-generation"): {200},
    ("GET", "/api/manager/autonomy/status"): {200},
    ("POST", "/api/manager/runs/start"): {202},
    ("POST", "/api/manager/runs/status"): {200},
    ("POST", "/api/manager/runs/control"): {200, 400},
}
EXPECTED_SUCCESS_STATUSES = {
    (spec["method"], spec["path"]): spec["success_status"]
    for spec in EXPECTED_ROUTE_SPECS
}

PUBLIC_ROUTES = {
    (spec["method"], spec["path"])
    for spec in EXPECTED_ROUTE_SPECS
    if spec["authorization"] == "public"
}
PROTECTED_ROUTES = {
    (spec["method"], spec["path"])
    for spec in EXPECTED_ROUTE_SPECS
    if spec["authorization"] == "bearer"
}

PAIR_PATTERN = re.compile(r'\("([A-Z]+)",\s*"(/api/manager[^"?]*)"\)')
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
TOKEN_PATTERN = re.compile(r"^[0-9a-f]{64}$")


class CheckFailure(RuntimeError):
    """A manager compatibility requirement was not met."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise CheckFailure(message)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def digest(path: pathlib.Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def aggregate_hash(values: dict[str, str]) -> str:
    value = hashlib.sha256()
    for path, file_hash in sorted(values.items()):
        value.update(path.encode("utf-8"))
        value.update(b"\0")
        value.update(file_hash.encode("ascii"))
        value.update(b"\n")
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
    require(path.is_file(), f"manager HTTP baseline is missing: {path}")
    require(digest(path) == EXPECTED_BASELINE_SHA256, "manager HTTP baseline digest changed")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise CheckFailure(f"cannot read manager HTTP baseline: {error}") from error
    require(isinstance(value, dict), "manager HTTP baseline must be a JSON object")
    require(
        set(value) == {
            "schema_version",
            "captured_at",
            "baseline_revision",
            "baseline_source_aggregate_sha256",
            "baseline_source_sha256",
            "limits",
            "baseline_routes",
            "current_routes",
            "envelopes",
            "security",
        },
        "manager HTTP baseline has missing or unknown top-level keys",
    )
    require(value["schema_version"] == 1, "unsupported manager HTTP baseline schema")
    require(value["captured_at"] == "2026-08-16T18:43:21Z", "baseline capture time changed")
    require(value["baseline_revision"] == EXPECTED_BASELINE_REVISION, "baseline revision changed")
    require(
        value["baseline_source_sha256"] == EXPECTED_BASELINE_SOURCE_SHA256,
        "baseline source hashes changed",
    )
    require(
        value["baseline_source_aggregate_sha256"]
        == EXPECTED_BASELINE_SOURCE_AGGREGATE_SHA256,
        "baseline source aggregate changed",
    )
    require(
        aggregate_hash(value["baseline_source_sha256"])
        == EXPECTED_BASELINE_SOURCE_AGGREGATE_SHA256,
        "baseline source aggregate is not reproducible",
    )
    require(value["baseline_routes"] == EXPECTED_BASELINE_ROUTES, "baseline routes changed")
    require(value["current_routes"] == EXPECTED_ROUTE_SPECS, "current route contract changed")
    validate_limits(value["limits"])
    validate_envelopes(value["envelopes"])
    validate_security(value["security"])
    return value


def validate_limits(value: Any) -> None:
    require(
        value == {
            "startup_timeout_seconds": 30,
            "request_timeout_seconds": 5,
            "shutdown_timeout_seconds": 20,
            "maximum_process_stdout_bytes": 262144,
            "maximum_process_stderr_bytes": 262144,
            "maximum_response_bytes": 262144,
            "maximum_redaction_scan_bytes": 4194304,
            "maximum_redaction_scan_files": 512,
        },
        "manager HTTP limits changed",
    )


def validate_envelopes(value: Any) -> None:
    require(isinstance(value, dict), "envelopes must be an object")
    require(
        set(value) == {
            "status_required_keys",
            "status_dashboard_required_keys",
            "settings_required_keys",
            "settings_shell_baseline_required_keys",
            "unauthorized",
            "invalid_manager_target",
            "invalid_snapshot_query",
            "invalid_run_control",
            "no_manager",
            "internal_error",
            "not_found",
            "shutdown",
        },
        "manager HTTP envelopes have missing or unknown keys",
    )
    require(
        value["unauthorized"]["body"]
        == {
            "ok": False,
            "code": "manager_mutation_unauthorized",
            "message": "Manager mutation authorization is required",
        },
        "unauthorized envelope changed",
    )
    require(value["unauthorized"]["status"] == 401, "unauthorized status changed")
    require(value["invalid_manager_target"]["status"] == 400, "target status changed")
    require(value["invalid_snapshot_query"]["status"] == 400, "snapshot status changed")
    require(value["invalid_run_control"]["status"] == 400, "run-control status changed")
    require(value["no_manager"]["status"] == 503, "no-manager status changed")
    require(value["internal_error"]["status"] == 500, "internal-error status changed")
    require(value["not_found"] == {"status": 404, "content_type": "text/plain", "body": "Not Found"}, "not-found contract changed")
    require(
        value["shutdown"]["body"]
        == {"ok": True, "message": "Manager shutting down", "state": "stopping"},
        "shutdown envelope changed",
    )


def validate_security(value: Any) -> None:
    require(isinstance(value, dict), "security contract must be an object")
    require(value["loopback_hosts"] == ["127.0.0.1", "localhost", "::1"], "loopback contract changed")
    require(value["credential_filename"] == "manager-control.secret", "credential path changed")
    require(value["credential_pattern"] == "^[0-9a-f]{64}$", "credential format changed")
    require(value["credential_permissions"] == "0600", "credential mode changed")
    require(value["maximum_authorization_header_bytes"] == 512, "authorization bound changed")
    require(value["maximum_request_header_bytes"] == 32768, "request-header bound changed")
    require(value["maximum_request_body_bytes"] == 1048576, "request-body bound changed")
    require(
        value["required_response_headers"]
        == {
            "cache-control": "no-store",
            "connection": "close",
            "cross-origin-resource-policy": "same-origin",
            "referrer-policy": "no-referrer",
            "x-content-type-options": "nosniff",
        },
        "required response headers changed",
    )
    require(
        value["content_security_policy"]
        == "default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'",
        "content security policy changed",
    )
    require(value["redaction_marker"] == "<redacted>", "redaction marker changed")


def braced_block(source: str, marker: str) -> str:
    try:
        marker_index = source.index(marker)
        start = source.index("{", marker_index)
    except ValueError as error:
        raise CheckFailure(f"source marker is missing: {marker}") from error
    depth = 0
    for index in range(start, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[start + 1:index]
    raise CheckFailure(f"source block is unterminated: {marker}")


def route_statuses(route_block: str) -> dict[tuple[str, str], set[int]]:
    boundaries = list(re.finditer(r"(?m)^\s*(case\s+|default\s*:)", route_block))
    observed: dict[tuple[str, str], set[int]] = {}
    for index, boundary in enumerate(boundaries):
        if boundary.group(1).startswith("default"):
            continue
        end = boundaries[index + 1].start() if index + 1 < len(boundaries) else len(route_block)
        segment = route_block[boundary.start():end]
        header, separator, body = segment.partition(":")
        require(bool(separator), "manager route case is malformed")
        pairs = [(method, path) for method, path in PAIR_PATTERN.findall(header)]
        statuses = {
            int(match.group(1))
            for match in re.finditer(
                r"http\.respond(?:JSON)?\(\s*connection,\s*status:\s*(\d+)",
                body,
                re.DOTALL,
            )
        }
        for pair in pairs:
            require(pair not in observed, f"duplicate manager route case: {pair}")
            observed[pair] = statuses
    return observed


def validate_current_sources() -> dict[str, Any]:
    source_hashes: dict[str, str] = {}
    sources: dict[str, str] = {}
    for relative in EXPECTED_BASELINE_SOURCE_SHA256:
        path = ROOT / relative
        require(path.is_file(), f"manager HTTP source is missing: {relative}")
        source_hashes[relative] = digest(path)
        try:
            sources[relative] = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            raise CheckFailure(f"cannot read manager HTTP source: {relative}: {error}") from error

    routes_source = sources["Sources/ForgeConductorCore/Dashboard/ManagerRoutes.swift"]
    route_block = braced_block(routes_source, "switch (method, target.path)")
    route_pairs = PAIR_PATTERN.findall(route_block)
    expected_pairs = [(spec["method"], spec["path"]) for spec in EXPECTED_ROUTE_SPECS]
    require(route_pairs == expected_pairs, "current manager route order or membership changed")
    require(
        {tuple(pair) for pair in EXPECTED_BASELINE_ROUTES}.issubset(set(route_pairs)),
        "a baseline manager route was removed",
    )

    direct_statuses = route_statuses(route_block)
    require(direct_statuses == EXPECTED_DIRECT_STATUSES, "manager route direct statuses changed")
    for spec in EXPECTED_ROUTE_SPECS:
        pair = (spec["method"], spec["path"])
        require(
            spec["success_status"] in direct_statuses[pair],
            f"manager route success status is absent: {pair}",
        )

    authorization_block = braced_block(routes_source, "switch (method.uppercased(), path)")
    require(set(PAIR_PATTERN.findall(authorization_block)) == PUBLIC_ROUTES, "public manager route set changed")

    required_markers = {
        "Sources/ForgeConductorCore/Dashboard/ManagerRoutes.swift": [
            "public static let maximumAuthorizationHeaderBytes = 512",
            "public static let tokenByteCount = 32",
            "metadata.st_uid == geteuid()",
            "permissions == mode_t(S_IRUSR | S_IWUSR)",
            '"invalid_manager_target"',
            '"manager_mutation_unauthorized"',
            '"invalid_snapshot_query"',
            '"invalid_run_control"',
            '"message": "Manager shutting down"',
            '"state": "stopping"',
            "manager.requestShutdown(delayMs: 350)",
            'body: "Not Found", contentType: "text/plain"',
            "rawTarget.utf8.count <= 4_096",
            "(1...100).contains(parsed)",
        ],
        "Sources/ForgeConductorCore/Dashboard/DashboardServer.swift": [
            'path.hasPrefix("/api/manager")',
            '"code": "no_manager"',
            'status: 500, object: ["ok": false, "message": "\\(error)"]',
        ],
        "Sources/ForgeConductorCore/Dashboard/DashboardHTTPRequest.swift": [
            "public static let maximumHeaderBytes = 32 * 1024",
            "public static let maximumBodyBytes = 1024 * 1024",
            'return (403, "Dashboard requests must target the local server")',
            'return (415, "State-changing dashboard requests require application/json")',
            'return (403, "Cross-origin dashboard requests are not allowed")',
        ],
        "Sources/ForgeConductorCore/Dashboard/HTTPResponder.swift": [
            'case 401: reason = "Unauthorized"',
            'header += "Connection: close\\r\\n"',
            'header += "Cache-Control: no-store\\r\\n"',
            '"X-Content-Type-Options: nosniff\\r\\n"',
            '"Referrer-Policy: no-referrer\\r\\n"',
            '"Cross-Origin-Resource-Policy: same-origin\\r\\n"',
            "Content-Security-Policy: default-src 'self'",
        ],
        "Sources/ForgeConductorCore/Infrastructure/AppPaths.swift": [
            'home.appendingPathComponent("manager-control.secret")',
            "never",
            "status",
            "diagnostics",
            "exports",
        ],
        "Sources/ForgeConductorCore/Manager/ManagerNode.swift": [
            "private static let operatorRedactor = ProjectMemoryRedactor()",
            "operatorRedactor.redact(value)",
            'return "<redacted>"',
        ],
        "Sources/ForgeConductorCore/Domain/ManagerModels.swift": [
            '"desired_running"',
            '"http_listening"',
            '"service_active"',
            '"default_timeout_sec"',
            'case mission, state',
        ],
    }
    for relative, markers in required_markers.items():
        source = sources[relative]
        for marker in markers:
            require(marker in source, f"manager HTTP source contract is missing marker in {relative}: {marker}")

    return {
        "source_sha256": source_hashes,
        "source_aggregate_sha256": aggregate_hash(source_hashes),
        "route_pairs": [list(pair) for pair in route_pairs],
        "public_route_pairs": [list(pair) for pair in sorted(PUBLIC_ROUTES)],
        "protected_route_pairs": [list(pair) for pair in sorted(PROTECTED_ROUTES)],
        "direct_statuses": {
            f"{method} {path}": sorted(statuses)
            for (method, path), statuses in direct_statuses.items()
        },
    }


class BoundedPipeReader:
    def __init__(self, stream: Any, limit: int) -> None:
        self._stream = stream
        self._limit = limit
        self._buffer = bytearray()
        self._overflow = False
        self._lock = threading.Lock()
        self._thread = threading.Thread(target=self._read, daemon=True)
        self._thread.start()

    def _read(self) -> None:
        try:
            while True:
                block = self._stream.read(16384)
                if not block:
                    return
                with self._lock:
                    remaining = self._limit - len(self._buffer)
                    if remaining > 0:
                        self._buffer.extend(block[:remaining])
                    if len(block) > remaining:
                        self._overflow = True
        finally:
            try:
                self._stream.close()
            except OSError:
                pass

    def snapshot(self) -> tuple[bytes, bool]:
        with self._lock:
            return bytes(self._buffer), self._overflow

    def join(self, timeout: float) -> None:
        self._thread.join(timeout)


class BoundedProcess:
    def __init__(
        self,
        command: list[str],
        environment: dict[str, str],
        stdout_limit: int,
        stderr_limit: int,
    ) -> None:
        try:
            self.process = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=ROOT,
                env=environment,
                start_new_session=True,
            )
        except OSError as error:
            raise CheckFailure(f"cannot launch executable probe: {error}") from error
        require(self.process.stdout is not None, "probe stdout pipe is missing")
        require(self.process.stderr is not None, "probe stderr pipe is missing")
        self.stdout = BoundedPipeReader(self.process.stdout, stdout_limit)
        self.stderr = BoundedPipeReader(self.process.stderr, stderr_limit)

    def require_output_within_limits(self) -> None:
        _, stdout_overflow = self.stdout.snapshot()
        _, stderr_overflow = self.stderr.snapshot()
        require(not stdout_overflow, "probe exceeded bounded stdout")
        require(not stderr_overflow, "probe exceeded bounded stderr")

    def terminate(self, timeout_seconds: int) -> tuple[int, bool]:
        graceful = True
        if self.process.poll() is None:
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        try:
            exit_code = self.process.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            graceful = False
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                exit_code = self.process.wait(timeout=5)
            except subprocess.TimeoutExpired as error:
                raise CheckFailure("probe did not terminate after SIGKILL") from error
        self.stdout.join(2)
        self.stderr.join(2)
        self.require_output_within_limits()
        return exit_code, graceful


@dataclass(frozen=True)
class HTTPResult:
    status: int
    headers: dict[str, str]
    body: bytes


def request(
    port: int,
    method: str,
    target: str,
    *,
    headers: dict[str, str] | None,
    body: bytes | None,
    timeout_seconds: int,
    maximum_response_bytes: int,
) -> HTTPResult:
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout_seconds)
    try:
        connection.request(method, target, body=body, headers=headers or {})
        response = connection.getresponse()
        raw_length = response.getheader("Content-Length")
        require(raw_length is not None and raw_length.isdecimal(), "response Content-Length is invalid")
        declared_length = int(raw_length)
        require(declared_length <= maximum_response_bytes, "response exceeds declared body bound")
        response_body = response.read(maximum_response_bytes + 1)
        require(len(response_body) <= maximum_response_bytes, "response exceeds body bound")
        require(len(response_body) == declared_length, "response Content-Length does not match body")
        response_headers = {name.lower(): value for name, value in response.getheaders()}
        return HTTPResult(status=response.status, headers=response_headers, body=response_body)
    except (OSError, http.client.HTTPException) as error:
        raise CheckFailure(f"loopback HTTP request failed for {method} {target}: {type(error).__name__}") from error
    finally:
        connection.close()


def raw_request(
    port: int,
    payload: bytes,
    *,
    timeout_seconds: int,
    maximum_response_bytes: int,
) -> HTTPResult:
    received = bytearray()
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout_seconds) as connection:
            connection.settimeout(timeout_seconds)
            connection.sendall(payload)
            connection.shutdown(socket.SHUT_WR)
            while True:
                block = connection.recv(min(16384, maximum_response_bytes - len(received) + 1))
                if not block:
                    break
                received.extend(block)
                require(len(received) <= maximum_response_bytes, "raw HTTP response exceeds bound")
    except OSError as error:
        raise CheckFailure(f"raw loopback HTTP request failed: {type(error).__name__}") from error
    header, separator, body = bytes(received).partition(b"\r\n\r\n")
    require(bool(separator), "raw HTTP response is missing its header boundary")
    lines = header.split(b"\r\n")
    require(lines and lines[0].startswith(b"HTTP/1.1 "), "raw HTTP status line is invalid")
    status_parts = lines[0].split(b" ", 2)
    require(len(status_parts) == 3 and status_parts[1].isdigit(), "raw HTTP status is invalid")
    headers: dict[str, str] = {}
    for line in lines[1:]:
        name, colon, value = line.partition(b":")
        require(bool(colon), "raw HTTP response header is invalid")
        headers[name.decode("ascii").lower()] = value.strip().decode("utf-8")
    require(headers.get("content-length", "").isdigit(), "raw response Content-Length is invalid")
    require(int(headers["content-length"]) == len(body), "raw response Content-Length mismatch")
    return HTTPResult(status=int(status_parts[1]), headers=headers, body=body)


def parse_json(result: HTTPResult, label: str) -> dict[str, Any]:
    require(
        result.headers.get("content-type") == "application/json; charset=utf-8",
        f"{label} content type changed",
    )
    try:
        value = json.loads(result.body)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise CheckFailure(f"{label} body is not valid JSON") from error
    require(isinstance(value, dict), f"{label} body must be a JSON object")
    return value


def require_common_headers(result: HTTPResult, contract: dict[str, Any], label: str) -> None:
    for name, expected in contract["security"]["required_response_headers"].items():
        require(result.headers.get(name) == expected, f"{label} response header changed: {name}")
    require(
        result.headers.get("content-security-policy")
        == contract["security"]["content_security_policy"],
        f"{label} content security policy changed",
    )
    require("access-control-allow-origin" not in result.headers, f"{label} exposed a CORS header")


def require_exact_json(
    result: HTTPResult,
    expected_status: int,
    expected_body: dict[str, Any],
    contract: dict[str, Any],
    label: str,
) -> dict[str, Any]:
    require(result.status == expected_status, f"{label} status changed")
    require_common_headers(result, contract, label)
    value = parse_json(result, label)
    require(value == expected_body, f"{label} envelope changed")
    return value


def require_required_json(
    result: HTTPResult,
    expected_status: int,
    required: dict[str, Any],
    contract: dict[str, Any],
    label: str,
) -> dict[str, Any]:
    require(result.status == expected_status, f"{label} status changed")
    require_common_headers(result, contract, label)
    value = parse_json(result, label)
    for key, expected in required.items():
        require(value.get(key) == expected, f"{label} required value changed: {key}")
    require(isinstance(value.get("message"), str) and value["message"], f"{label} message is absent")
    return value


def reserve_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as candidate:
        candidate.bind(("127.0.0.1", 0))
        port = candidate.getsockname()[1]
    require(1024 <= port <= 65535, "ephemeral loopback port is invalid")
    return int(port)


def write_probe_config(probe_dir: pathlib.Path, port: int) -> None:
    probe_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
    task_tmp = probe_dir / "tmp"
    task_tmp.mkdir(mode=0o700)
    config = {
        "config_schema_version": 2,
        "log_level": "error",
        "allowed_roots": [],
        "shell": {
            "enabled": True,
            "user_disabled": False,
            "policy_version": 2,
            "policy_origin": "default_enabled",
            "default_timeout_sec": 30,
        },
        "dashboard": {"host": "127.0.0.1", "port": port, "refresh_interval_sec": 8},
        "manager": {
            "auto_restart": True,
            "watchdog_interval_sec": 3,
            "open_browser_on_start": False,
        },
        "mcp": {"role": "primary"},
        "sessions": {"idle_ttl_sec": 14400},
        "coordinator": {"enabled": True, "lease_ttl_sec": 60, "presence_ttl_sec": 30},
    }
    data = (json.dumps(config, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    descriptor = os.open(probe_dir / "config.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        view = memoryview(data)
        while view:
            written = os.write(descriptor, view)
            require(written > 0, "probe config write did not progress")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def probe_environment(probe_dir: pathlib.Path) -> dict[str, str]:
    environment = dict(os.environ)
    for key in list(environment):
        if key.startswith("FORGE_"):
            environment.pop(key, None)
    environment["FORGE_CONDUCTOR_HOME"] = str(probe_dir)
    environment["FORGE_SKIP_PS"] = "1"
    environment["TMPDIR"] = str(probe_dir / "tmp")
    return environment


def wait_for_http(
    process: BoundedProcess,
    port: int,
    contract: dict[str, Any],
) -> HTTPResult:
    limits = contract["limits"]
    deadline = time.monotonic() + limits["startup_timeout_seconds"]
    while time.monotonic() < deadline:
        process.require_output_within_limits()
        if process.process.poll() is not None:
            raise CheckFailure(f"manager probe exited before readiness with code {process.process.returncode}")
        try:
            result = request(
                port,
                "GET",
                "/api/manager/status",
                headers=None,
                body=None,
                timeout_seconds=1,
                maximum_response_bytes=limits["maximum_response_bytes"],
            )
            if result.status == 200:
                return result
        except CheckFailure:
            pass
        time.sleep(0.05)
    raise CheckFailure("manager probe did not become ready within its bounded deadline")


def response_summary(case_id: str, result: HTTPResult) -> dict[str, Any]:
    return {
        "id": case_id,
        "status": result.status,
        "content_type": result.headers.get("content-type"),
        "body_bytes": len(result.body),
        "body_sha256": sha256_bytes(result.body),
    }


def scan_for_credential(
    probe_dir: pathlib.Path,
    credential_path: pathlib.Path,
    token: str,
    contract: dict[str, Any],
) -> dict[str, int]:
    limits = contract["limits"]
    allowed_roots = [
        probe_dir / "config.json",
        probe_dir / "manager-state.json",
        probe_dir / "logs",
        probe_dir / "exports",
        probe_dir / "memory",
    ]
    candidates: list[pathlib.Path] = []
    for root in allowed_roots:
        if not root.exists():
            continue
        if root.is_file():
            candidates.append(root)
        else:
            candidates.extend(path for path in root.rglob("*") if path.is_file())
    candidates = sorted(set(candidates))
    require(
        len(candidates) <= limits["maximum_redaction_scan_files"],
        "redaction scan file bound exceeded",
    )
    total = 0
    token_bytes = token.encode("ascii")
    for path in candidates:
        require(path != credential_path, "credential file entered the noncredential scan")
        require(not path.is_symlink(), "redaction scan encountered a symbolic link")
        file_size = path.stat().st_size
        total += file_size
        require(total <= limits["maximum_redaction_scan_bytes"], "redaction scan byte bound exceeded")
        with path.open("rb") as stream:
            require(token_bytes not in stream.read(file_size + 1), "manager credential escaped protected storage")
    return {"files": len(candidates), "bytes": total}


def port_is_closed(port: int, timeout_seconds: float = 2.0) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                time.sleep(0.05)
        except OSError:
            return True
    return False


def run_manager_probe(
    binary: pathlib.Path,
    probe_dir: pathlib.Path,
    contract: dict[str, Any],
) -> dict[str, Any]:
    limits = contract["limits"]
    port = reserve_loopback_port()
    write_probe_config(probe_dir, port)
    environment = probe_environment(probe_dir)
    process = BoundedProcess(
        [str(binary), "manager", "run", "--home", str(probe_dir)],
        environment,
        limits["maximum_process_stdout_bytes"],
        limits["maximum_process_stderr_bytes"],
    )
    responses: list[tuple[str, HTTPResult]] = []
    observed_routes: set[tuple[str, str]] = set()
    observed_statuses: dict[tuple[str, str], set[int]] = {}
    success_semantics: set[tuple[str, str]] = set()
    run_fixture: dict[str, Any] | None = None
    exit_code: int | None = None
    graceful = False

    def observe_route(method: str, path: str, result: HTTPResult) -> None:
        pair = (method, path.split("?", 1)[0])
        observed_routes.add(pair)
        observed_statuses.setdefault(pair, set()).add(result.status)

    try:
        readiness = wait_for_http(process, port, contract)
        responses.append(("manager_ready", readiness))
        status = parse_json(readiness, "manager_ready")
        require_common_headers(readiness, contract, "manager_ready")
        required_status_keys = set(contract["envelopes"]["status_required_keys"])
        require(required_status_keys <= set(status), "manager status lost baseline keys")
        require(status.get("ok") is True and status.get("manager") is True, "manager status identity changed")
        require(status.get("state") == "running", "manager did not report running")
        require(status.get("service_active") is True, "manager service is not active")
        require(status.get("pid") == process.process.pid, "manager status PID changed")
        require(status.get("home") == str(probe_dir), "manager escaped its explicit temporary home")
        dashboard = status.get("dashboard")
        require(isinstance(dashboard, dict), "manager status dashboard envelope is absent")
        require(
            set(contract["envelopes"]["status_dashboard_required_keys"]) <= set(dashboard),
            "manager dashboard status lost baseline keys",
        )
        require(dashboard.get("host") == "127.0.0.1", "manager did not bind the loopback host")
        require(dashboard.get("port") == port, "manager did not bind the selected temporary port")
        observe_route("GET", "/api/manager/status", readiness)
        success_semantics.add(("GET", "/api/manager/status"))

        json_headers = {
            "Content-Type": "application/json",
            "Origin": f"http://127.0.0.1:{port}",
            "Sec-Fetch-Site": "same-origin",
        }
        wrong_auth_headers = {**json_headers, "Authorization": "Bearer invalid"}
        first_unauthorized = request(
            port,
            "POST",
            "/api/manager/start",
            headers=wrong_auth_headers,
            body=b"{}",
            timeout_seconds=limits["request_timeout_seconds"],
            maximum_response_bytes=limits["maximum_response_bytes"],
        )
        require_exact_json(
            first_unauthorized,
            401,
            contract["envelopes"]["unauthorized"]["body"],
            contract,
            "authorization_wrong_token",
        )
        responses.append(("authorization_wrong_token", first_unauthorized))
        observe_route("POST", "/api/manager/start", first_unauthorized)

        credential_path = probe_dir / contract["security"]["credential_filename"]
        require(credential_path.is_file() and not credential_path.is_symlink(), "credential was not created safely")
        metadata = credential_path.stat()
        require(stat.S_ISREG(metadata.st_mode), "credential is not a regular file")
        require(stat.S_IMODE(metadata.st_mode) == 0o600, "credential permissions changed")
        require(metadata.st_uid == os.geteuid(), "credential owner changed")
        require(metadata.st_size == 64, "credential length changed")
        try:
            token = credential_path.read_text(encoding="ascii")
        except (OSError, UnicodeError) as error:
            raise CheckFailure("credential could not be read for the isolated probe") from error
        require(TOKEN_PATTERN.fullmatch(token) is not None, "credential format changed")
        authorization_headers = {**json_headers, "Authorization": f"Bearer {token}"}

        def json_success(
            case_id: str,
            method: str,
            path: str,
            payload: dict[str, Any],
            *,
            request_headers: dict[str, str] | None = None,
        ) -> tuple[HTTPResult, dict[str, Any]]:
            result = request(
                port,
                method,
                path,
                headers=request_headers or authorization_headers,
                body=json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8"),
                timeout_seconds=limits["request_timeout_seconds"],
                maximum_response_bytes=limits["maximum_response_bytes"],
            )
            expected_status = EXPECTED_SUCCESS_STATUSES[(method, path)]
            require(result.status == expected_status, f"{case_id} success status changed")
            require_common_headers(result, contract, case_id)
            value = parse_json(result, case_id)
            require(value.get("ok") is True, f"{case_id} success envelope lost ok=true")
            responses.append((case_id, result))
            observe_route(method, path, result)
            success_semantics.add((method, path))
            return result, value

        public_cases = [
            ("status_query", "GET", "/api/manager/status?ignored=1", None, None, 200),
            ("settings", "GET", "/api/manager/settings", None, None, 200),
            ("operator_snapshot", "GET", "/api/manager/operator/snapshot?limit=1", None, None, 200),
            ("autonomy_status", "GET", "/api/manager/autonomy/status", None, None, 200),
            ("project_status_invalid", "POST", "/api/manager/projects/status", json_headers, b"{}", 500),
            ("run_status_invalid", "POST", "/api/manager/runs/status", json_headers, b"{}", 500),
        ]
        for case_id, method, target, headers, body, expected_status in public_cases:
            result = request(
                port,
                method,
                target,
                headers=headers,
                body=body,
                timeout_seconds=limits["request_timeout_seconds"],
                maximum_response_bytes=limits["maximum_response_bytes"],
            )
            require(result.status == expected_status, f"{case_id} status changed")
            require_common_headers(result, contract, case_id)
            value = parse_json(result, case_id)
            if expected_status == 200:
                if case_id != "operator_snapshot":
                    require(value.get("ok") is True, f"{case_id} success envelope changed")
            else:
                require(
                    set(value) == set(contract["envelopes"]["internal_error"]["required_keys"]),
                    f"{case_id} internal-error envelope changed",
                )
                require(value.get("ok") is False, f"{case_id} internal error lost ok=false")
                require(isinstance(value.get("message"), str) and value["message"], f"{case_id} message is absent")
            if case_id == "settings":
                require(
                    set(contract["envelopes"]["settings_required_keys"]) <= set(value),
                    "settings lost baseline keys",
                )
                shell = value.get("shell")
                require(isinstance(shell, dict), "settings shell envelope is absent")
                require(
                    set(contract["envelopes"]["settings_shell_baseline_required_keys"]) <= set(shell),
                    "settings shell lost baseline keys",
                )
            if case_id == "operator_snapshot":
                require(value.get("limit") == 1, "operator snapshot limit changed")
                for key in ["projects", "runs", "continuity_operations", "runtime_jobs", "events"]:
                    require(isinstance(value.get(key), list), f"operator snapshot {key} is not a list")
                    require(len(value[key]) <= 1, f"operator snapshot {key} exceeded its requested bound")
                require(isinstance(value.get("provider"), dict), "operator snapshot provider is absent")
                require(isinstance(value.get("runtime"), dict), "operator snapshot runtime is absent")
            responses.append((case_id, result))
            observe_route(method, target, result)
            if expected_status == EXPECTED_SUCCESS_STATUSES[(method, target.split("?", 1)[0])]:
                success_semantics.add((method, target.split("?", 1)[0]))

        for method, path in sorted(PROTECTED_ROUTES):
            if (method, path) == ("POST", "/api/manager/start"):
                continue
            headers = json_headers if method in {"POST", "PUT", "PATCH", "DELETE"} else None
            result = request(
                port,
                method,
                path,
                headers=headers,
                body=b"{}" if headers is not None else None,
                timeout_seconds=limits["request_timeout_seconds"],
                maximum_response_bytes=limits["maximum_response_bytes"],
            )
            case_id = "unauthorized_" + method.lower() + "_" + path.rsplit("/", 1)[-1].replace("-", "_")
            require_exact_json(
                result,
                401,
                contract["envelopes"]["unauthorized"]["body"],
                contract,
                case_id,
            )
            responses.append((case_id, result))
            observe_route(method, path, result)

        lowercase_scheme = request(
            port,
            "POST",
            "/api/manager/start",
            headers={**json_headers, "Authorization": f"bearer {token}"},
            body=b"{}",
            timeout_seconds=limits["request_timeout_seconds"],
            maximum_response_bytes=limits["maximum_response_bytes"],
        )
        require_exact_json(lowercase_scheme, 401, contract["envelopes"]["unauthorized"]["body"], contract, "authorization_scheme_case")
        responses.append(("authorization_scheme_case", lowercase_scheme))

        oversized_authorization = request(
            port,
            "POST",
            "/api/manager/start",
            headers={**json_headers, "Authorization": "Bearer " + "a" * 506},
            body=b"{}",
            timeout_seconds=limits["request_timeout_seconds"],
            maximum_response_bytes=limits["maximum_response_bytes"],
        )
        require_exact_json(oversized_authorization, 401, contract["envelopes"]["unauthorized"]["body"], contract, "authorization_oversized")
        responses.append(("authorization_oversized", oversized_authorization))

        os.chmod(credential_path, 0o644)
        try:
            unsafe_storage = request(
                port,
                "POST",
                "/api/manager/start",
                headers=authorization_headers,
                body=b"{}",
                timeout_seconds=limits["request_timeout_seconds"],
                maximum_response_bytes=limits["maximum_response_bytes"],
            )
            require_exact_json(unsafe_storage, 401, contract["envelopes"]["unauthorized"]["body"], contract, "authorization_storage_fail_closed")
            responses.append(("authorization_storage_fail_closed", unsafe_storage))
        finally:
            os.chmod(credential_path, 0o600)

        invalid_target = request(
            port,
            "GET",
            "/api/manager/status#fragment",
            headers=None,
            body=None,
            timeout_seconds=limits["request_timeout_seconds"],
            maximum_response_bytes=limits["maximum_response_bytes"],
        )
        require_required_json(invalid_target, 400, contract["envelopes"]["invalid_manager_target"]["required"], contract, "invalid_manager_target")
        responses.append(("invalid_manager_target", invalid_target))

        invalid_snapshot = request(
            port,
            "GET",
            "/api/manager/operator/snapshot?limit=0",
            headers=None,
            body=None,
            timeout_seconds=limits["request_timeout_seconds"],
            maximum_response_bytes=limits["maximum_response_bytes"],
        )
        require_required_json(invalid_snapshot, 400, contract["envelopes"]["invalid_snapshot_query"]["required"], contract, "invalid_snapshot_query")
        responses.append(("invalid_snapshot_query", invalid_snapshot))

        invalid_run_control = request(
            port,
            "POST",
            "/api/manager/runs/control",
            headers=authorization_headers,
            body=b"{}",
            timeout_seconds=limits["request_timeout_seconds"],
            maximum_response_bytes=limits["maximum_response_bytes"],
        )
        require_exact_json(invalid_run_control, 400, contract["envelopes"]["invalid_run_control"]["body"], contract, "invalid_run_control")
        responses.append(("invalid_run_control", invalid_run_control))
        observe_route("POST", "/api/manager/runs/control", invalid_run_control)

        unknown_without_auth = request(
            port,
            "GET",
            "/api/manager/not-a-route",
            headers=None,
            body=None,
            timeout_seconds=limits["request_timeout_seconds"],
            maximum_response_bytes=limits["maximum_response_bytes"],
        )
        require_exact_json(unknown_without_auth, 401, contract["envelopes"]["unauthorized"]["body"], contract, "unknown_without_authorization")
        responses.append(("unknown_without_authorization", unknown_without_auth))

        unknown_with_auth = request(
            port,
            "GET",
            "/api/manager/not-a-route",
            headers={"Authorization": f"Bearer {token}"},
            body=None,
            timeout_seconds=limits["request_timeout_seconds"],
            maximum_response_bytes=limits["maximum_response_bytes"],
        )
        require(unknown_with_auth.status == 404, "authorized unknown manager path status changed")
        require_common_headers(unknown_with_auth, contract, "authorized_not_found")
        require(unknown_with_auth.headers.get("content-type") == "text/plain", "not-found content type changed")
        require(unknown_with_auth.body == b"Not Found", "not-found body changed")
        responses.append(("authorized_not_found", unknown_with_auth))

        wrong_method_without_auth = request(
            port,
            "DELETE",
            "/api/manager/status",
            headers=json_headers,
            body=b"{}",
            timeout_seconds=limits["request_timeout_seconds"],
            maximum_response_bytes=limits["maximum_response_bytes"],
        )
        require_exact_json(wrong_method_without_auth, 401, contract["envelopes"]["unauthorized"]["body"], contract, "wrong_method_without_authorization")
        responses.append(("wrong_method_without_authorization", wrong_method_without_auth))

        wrong_method_with_auth = request(
            port,
            "DELETE",
            "/api/manager/status",
            headers=authorization_headers,
            body=b"{}",
            timeout_seconds=limits["request_timeout_seconds"],
            maximum_response_bytes=limits["maximum_response_bytes"],
        )
        require(wrong_method_with_auth.status == 404 and wrong_method_with_auth.body == b"Not Found", "authorized wrong-method contract changed")
        require_common_headers(wrong_method_with_auth, contract, "wrong_method_authorized")
        responses.append(("wrong_method_authorized", wrong_method_with_auth))

        policy_cases = [
            (
                "bad_host",
                "GET",
                "/api/manager/status",
                {"Host": "attacker.example"},
                None,
                contract["security"]["host_rejection"],
            ),
            (
                "non_json_mutation",
                "POST",
                "/api/manager/start",
                {"Content-Type": "text/plain"},
                b"{}",
                contract["security"]["content_type_rejection"],
            ),
            (
                "cross_origin",
                "POST",
                "/api/manager/start",
                {"Content-Type": "application/json", "Origin": "https://attacker.example"},
                b"{}",
                contract["security"]["origin_rejection"],
            ),
            (
                "cross_site_fetch",
                "POST",
                "/api/manager/start",
                {"Content-Type": "application/json", "Sec-Fetch-Site": "cross-site"},
                b"{}",
                contract["security"]["origin_rejection"],
            ),
        ]
        for case_id, method, target, headers, body, expected in policy_cases:
            result = request(
                port,
                method,
                target,
                headers=headers,
                body=body,
                timeout_seconds=limits["request_timeout_seconds"],
                maximum_response_bytes=limits["maximum_response_bytes"],
            )
            require(result.status == expected["status"], f"{case_id} policy status changed")
            require_common_headers(result, contract, case_id)
            require(result.headers.get("content-type") == "text/plain", f"{case_id} content type changed")
            require(result.body.decode("utf-8") == expected["body"], f"{case_id} policy body changed")
            responses.append((case_id, result))

        raw_cases = [
            (
                "parser_invalid_content_length",
                b"POST /api/manager/start HTTP/1.1\r\nHost: 127.0.0.1:" + str(port).encode("ascii") + b"\r\nContent-Length:\r\n\r\n",
                400,
                b"Invalid Content-Length",
            ),
            (
                "parser_transfer_encoding",
                b"POST /api/manager/start HTTP/1.1\r\nHost: 127.0.0.1:" + str(port).encode("ascii") + b"\r\nTransfer-Encoding: chunked\r\n\r\n",
                400,
                b"Transfer-Encoding is not supported",
            ),
            (
                "parser_body_too_large",
                b"POST /api/manager/start HTTP/1.1\r\nHost: 127.0.0.1:" + str(port).encode("ascii") + b"\r\nContent-Length: 1048577\r\n\r\n",
                413,
                b"Request body too large",
            ),
        ]
        for case_id, payload, expected_status, expected_body in raw_cases:
            result = raw_request(
                port,
                payload,
                timeout_seconds=limits["request_timeout_seconds"],
                maximum_response_bytes=limits["maximum_response_bytes"],
            )
            require(result.status == expected_status, f"{case_id} status changed")
            require_common_headers(result, contract, case_id)
            require(result.headers.get("content-type") == "text/plain", f"{case_id} content type changed")
            require(result.body == expected_body, f"{case_id} body changed")
            responses.append((case_id, result))

        _, start_value = json_success(
            "authenticated_start",
            "POST",
            "/api/manager/start",
            {},
        )
        require(required_status_keys <= set(start_value), "authenticated start lost status keys")
        require(
            start_value.get("state") == "running"
            and start_value.get("desired_running") is True
            and start_value.get("service_active") is True,
            "authenticated start did not preserve running semantics",
        )

        settings_payload = {"apply": False, "settings": {"log_level": "error"}}
        for case_id, method in (
            ("authenticated_settings_post", "POST"),
            ("authenticated_settings_put", "PUT"),
        ):
            _, settings_value = json_success(
                case_id,
                method,
                "/api/manager/settings",
                settings_payload,
            )
            require(
                set(contract["envelopes"]["settings_required_keys"]) <= set(settings_value),
                f"{case_id} lost settings keys",
            )
            require(settings_value.get("applied") is False, f"{case_id} changed apply=false semantics")
            require(settings_value.get("bind_changed") is False, f"{case_id} unexpectedly changed binding")
            require(isinstance(settings_value.get("status"), dict), f"{case_id} lost status projection")

        project_fixture = probe_dir / "project-fixture"
        project_fixture.mkdir(mode=0o700)
        _, registered = json_success(
            "authenticated_project_register",
            "POST",
            "/api/manager/projects/register",
            {"path": str(project_fixture), "display_name": "P10 manager HTTP fixture"},
        )
        project_id = registered.get("project_id")
        project_generation = registered.get("project_generation")
        require(isinstance(project_id, str) and project_id, "project registration lost its identifier")
        require(
            isinstance(project_generation, int) and project_generation > 0,
            "project registration lost its generation",
        )
        registered_root = registered.get("canonical_root")
        require(isinstance(registered_root, str) and registered_root, "project registration lost its root")
        require(
            pathlib.Path(registered_root).resolve() == project_fixture.resolve(),
            "project registration escaped the temporary fixture",
        )

        _, project_status = json_success(
            "authenticated_project_status",
            "POST",
            "/api/manager/projects/status",
            {"project_id": project_id},
        )
        require(project_status.get("project_id") == project_id, "project status identifier changed")
        require(
            project_status.get("project_generation") == project_generation,
            "project status generation changed",
        )

        owner_id = "p10-manager-http-probe"
        _, binding = json_success(
            "authenticated_project_bind",
            "POST",
            "/api/manager/projects/bind",
            {
                "project_id": project_id,
                "project_generation": project_generation,
                "owner_kind": "mcp_client",
                "owner_id": owner_id,
                "allowed_tools": ["project_memory.search"],
                "network_allowed": False,
                "maximum_inline_output_bytes": 1024,
            },
        )
        require(binding.get("project_id") == project_id, "project binding identifier changed")
        require(binding.get("project_generation") == project_generation, "project binding generation changed")
        require(binding.get("owner_kind") == "mcp_client", "project binding owner kind changed")
        require(binding.get("owner_id") == owner_id, "project binding owner identifier changed")
        require(binding.get("network_allowed") is False, "project binding network scope changed")
        require(
            binding.get("maximum_inline_output_bytes") == 1024,
            "project binding inline-output bound changed",
        )

        _, reset = json_success(
            "authenticated_project_reset_generation",
            "POST",
            "/api/manager/projects/reset-generation",
            {"project_id": project_id, "project_generation": project_generation},
        )
        require(reset.get("project_id") == project_id, "project reset identifier changed")
        require(reset.get("prior_generation") == project_generation, "project reset prior generation changed")
        require(
            reset.get("new_generation") == project_generation + 1,
            "project reset did not advance generation once",
        )
        require(
            isinstance(reset.get("invalidated_binding_count"), int)
            and reset["invalidated_binding_count"] >= 1,
            "project reset did not invalidate the temporary binding",
        )

        run_request = {
            "run_id": RUN_FIXTURE_ID,
            "project_id": project_id,
            "project_generation": reset["new_generation"],
            "mission": "Exercise isolated manager run-route semantics",
            "provider_id": RUN_FIXTURE_PROVIDER_ID,
            "adapter_id": RUN_FIXTURE_ADAPTER_ID,
            "model_key": RUN_FIXTURE_MODEL_KEY,
            "allowed_tools": ["project_memory.search"],
            "completion_gates": ["p10_manager_http_route"],
            "network_allowed": False,
            "maximum_inline_output_bytes": 1_024,
        }
        _, started_run = json_success(
            "authenticated_run_start",
            "POST",
            "/api/manager/runs/start",
            run_request,
        )
        require(started_run.get("run_id") == RUN_FIXTURE_ID, "run start identifier changed")
        require(started_run.get("project_id") == project_id, "run start project changed")
        require(
            started_run.get("project_generation") == reset["new_generation"],
            "run start generation changed",
        )
        require(
            started_run.get("continuity_mode") == "managedAutonomous",
            "run start continuity mode changed",
        )
        require(
            started_run.get("provider_id") == RUN_FIXTURE_PROVIDER_ID,
            "run start provider identity changed",
        )
        require(
            started_run.get("adapter_id") == RUN_FIXTURE_ADAPTER_ID,
            "run start adapter identity changed",
        )
        require(
            started_run.get("model_key") == RUN_FIXTURE_MODEL_KEY,
            "run start model identity changed",
        )
        require(
            started_run.get("state") == RUN_FIXTURE_INITIAL_STATE,
            "run start did not return the newly created durable run",
        )
        require(
            started_run.get("revision") == RUN_FIXTURE_INITIAL_REVISION,
            "run start did not return the initial durable revision",
        )
        require(
            "last_error_code" not in started_run
            and "last_error_summary" not in started_run
            and "retry_at" not in started_run,
            "run start returned an unrelated failure or retry condition",
        )

        run_status_result: HTTPResult | None = None
        run_status: dict[str, Any] | None = None
        observed_run_progression: list[dict[str, Any]] = [{
            "state": RUN_FIXTURE_INITIAL_STATE,
            "revision": RUN_FIXTURE_INITIAL_REVISION,
        }]
        prior_revision = RUN_FIXTURE_INITIAL_REVISION
        run_deadline = time.monotonic() + limits["request_timeout_seconds"]
        while time.monotonic() < run_deadline:
            candidate_result = request(
                port,
                "POST",
                "/api/manager/runs/status",
                headers=json_headers,
                body=json.dumps(
                    {"run_id": RUN_FIXTURE_ID}, sort_keys=True, separators=(",", ":")
                ).encode("utf-8"),
                timeout_seconds=limits["request_timeout_seconds"],
                maximum_response_bytes=limits["maximum_response_bytes"],
            )
            require(
                candidate_result.status
                == EXPECTED_SUCCESS_STATUSES[("POST", "/api/manager/runs/status")],
                "public_run_status success status changed",
            )
            require_common_headers(candidate_result, contract, "public_run_status")
            candidate = parse_json(candidate_result, "public_run_status")
            require(candidate.get("ok") is True, "public_run_status success envelope lost ok=true")
            require(candidate.get("run_id") == RUN_FIXTURE_ID, "run status identifier changed")
            state = candidate.get("state")
            revision = candidate.get("revision")
            require(
                isinstance(state, str)
                and type(revision) is int
                and revision in RUN_FIXTURE_PROGRESS_REVISIONS.get(state, set()),
                "run status escaped the deterministic unregistered-adapter progression",
            )
            require(revision >= prior_revision, "run status revision moved backwards")
            prior_revision = revision
            if observed_run_progression[-1] != {"state": state, "revision": revision}:
                observed_run_progression.append({"state": state, "revision": revision})
            if state == RUN_FIXTURE_CAUSAL_STATE:
                run_status_result = candidate_result
                run_status = candidate
                break
            time.sleep(0.02)

        require(
            run_status_result is not None and run_status is not None,
            "unregistered-adapter run did not reach its causal waiting state",
        )
        require(
            run_status.get("revision") == RUN_FIXTURE_CAUSAL_REVISION,
            "unregistered-adapter run reached an unexpected causal revision",
        )
        require(
            run_status.get("last_error_code") == RUN_FIXTURE_CAUSAL_ERROR_CODE,
            "unregistered-adapter run did not preserve its exact causal error code",
        )
        require(
            run_status.get("last_error_summary") == RUN_FIXTURE_CAUSAL_ERROR_SUMMARY,
            "unregistered-adapter run did not preserve its exact causal error summary",
        )
        require(
            isinstance(run_status.get("retry_at"), str) and bool(run_status["retry_at"]),
            "unregistered-adapter run did not persist its bounded retry time",
        )
        responses.append(("public_run_status", run_status_result))
        observe_route("POST", "/api/manager/runs/status", run_status_result)
        success_semantics.add(("POST", "/api/manager/runs/status"))

        run_event_result = request(
            port,
            "GET",
            "/api/manager/operator/snapshot?limit=100",
            headers=None,
            body=None,
            timeout_seconds=limits["request_timeout_seconds"],
            maximum_response_bytes=limits["maximum_response_bytes"],
        )
        require(run_event_result.status == 200, "run event snapshot status changed")
        require_common_headers(run_event_result, contract, "run_event_snapshot")
        run_event_snapshot = parse_json(run_event_result, "run_event_snapshot")
        run_events = [
            event for event in run_event_snapshot.get("events", [])
            if isinstance(event, dict) and event.get("run_id") == RUN_FIXTURE_ID
        ]
        require(
            [event.get("kind") for event in run_events]
            == RUN_FIXTURE_EVENT_KINDS_NEWEST_FIRST,
            "unregistered-adapter run event progression changed: "
            + repr([event.get("kind") for event in run_events]),
        )
        causal_event = run_events[0]
        require(
            causal_event.get("kind") == RUN_FIXTURE_CAUSAL_EVENT_KIND
            and causal_event.get("summary") == RUN_FIXTURE_CAUSAL_EVENT_SUMMARY
            and causal_event.get("severity") == "warning",
            "unregistered-adapter run causal event changed",
        )
        responses.append(("run_event_snapshot", run_event_result))

        _, paused_run = json_success(
            "authenticated_run_pause",
            "POST",
            "/api/manager/runs/control",
            {"run_id": RUN_FIXTURE_ID, "action": "pause"},
        )
        require(paused_run.get("run_id") == RUN_FIXTURE_ID, "run control identifier changed")
        require(paused_run.get("state") == "paused", "run control did not persist pause")
        require(
            paused_run.get("revision") == RUN_FIXTURE_CAUSAL_REVISION + 1,
            "run control did not advance exactly one durable revision",
        )

        _, paused_status = json_success(
            "public_run_status_after_pause",
            "POST",
            "/api/manager/runs/status",
            {"run_id": RUN_FIXTURE_ID},
            request_headers=json_headers,
        )
        require(paused_status.get("run_id") == RUN_FIXTURE_ID, "paused status identifier changed")
        require(paused_status.get("state") == "paused", "paused status was not durable")
        require(
            paused_status.get("revision") == paused_run.get("revision"),
            "paused status revision changed after control",
        )

        _, replayed_run = json_success(
            "authenticated_run_start_replay",
            "POST",
            "/api/manager/runs/start",
            run_request,
        )
        require(replayed_run.get("run_id") == RUN_FIXTURE_ID, "run replay identifier changed")
        require(replayed_run.get("state") == "paused", "run replay did not preserve durable state")
        require(
            replayed_run == paused_status,
            "run replay was not idempotent",
        )
        run_fixture = {
            "mode": "temporary_project_unregistered_adapter",
            "run_id": RUN_FIXTURE_ID,
            "project_generation": reset["new_generation"],
            "start_status": EXPECTED_SUCCESS_STATUSES[("POST", "/api/manager/runs/start")],
            "status_status": EXPECTED_SUCCESS_STATUSES[("POST", "/api/manager/runs/status")],
            "control_status": EXPECTED_SUCCESS_STATUSES[("POST", "/api/manager/runs/control")],
            "causal_state": run_status["state"],
            "causal_revision": run_status["revision"],
            "causal_error_code": run_status["last_error_code"],
            "causal_error_summary": run_status["last_error_summary"],
            "causal_event_kind": causal_event["kind"],
            "causal_event_summary": causal_event["summary"],
            "event_progression_newest_first": [event["kind"] for event in run_events],
            "observed_progression": observed_run_progression + [
                {"state": paused_status["state"], "revision": paused_status["revision"]}
            ],
            "final_state": paused_status["state"],
            "idempotent_start_replay": True,
        }

        _, stop_value = json_success(
            "authenticated_stop",
            "POST",
            "/api/manager/stop",
            {},
        )
        require(required_status_keys <= set(stop_value), "authenticated stop lost status keys")
        require(
            stop_value.get("state") == "stopped"
            and stop_value.get("desired_running") is False
            and stop_value.get("service_active") is False,
            "authenticated stop did not preserve stopped semantics",
        )

        _, resumed = json_success(
            "authenticated_start_after_stop",
            "POST",
            "/api/manager/start",
            {},
        )
        require(required_status_keys <= set(resumed), "authenticated resumed start lost status keys")
        require(
            resumed.get("state") == "running"
            and resumed.get("desired_running") is True
            and resumed.get("service_active") is True,
            "authenticated start after stop did not restore running semantics",
        )

        _, restarted = json_success(
            "authenticated_restart",
            "POST",
            "/api/manager/restart",
            {},
        )
        require(required_status_keys <= set(restarted), "authenticated restart lost status keys")
        require(
            restarted.get("state") == "running"
            and restarted.get("service_active") is True
            and isinstance(restarted.get("restart_count"), int)
            and restarted["restart_count"] >= 1,
            "authenticated restart did not preserve running semantics",
        )

        shutdown_result, shutdown_value = json_success(
            "authenticated_shutdown",
            "POST",
            "/api/manager/shutdown",
            {},
        )
        require(
            shutdown_value == contract["envelopes"]["shutdown"]["body"],
            "authenticated shutdown envelope changed",
        )
        require(
            shutdown_result.status == contract["envelopes"]["shutdown"]["status"],
            "authenticated shutdown status changed",
        )

        expected_routes = set(EXPECTED_DIRECT_STATUSES)
        require(observed_routes == expected_routes, "runtime did not observe every current route pair")
        require(
            success_semantics <= expected_routes,
            "runtime recorded an unknown success semantic",
        )
        baseline_successes = {tuple(pair) for pair in EXPECTED_BASELINE_ROUTES}
        require(
            baseline_successes <= success_semantics,
            "runtime did not exercise every preserved baseline success semantic",
        )
        token_bytes = token.encode("ascii")
        for case_id, result in responses:
            require(token_bytes not in result.body, f"manager credential appeared in response body: {case_id}")
            require(
                all(token not in value for value in result.headers.values()),
                f"manager credential appeared in response headers: {case_id}",
            )
        scan = scan_for_credential(probe_dir, credential_path, token, contract)
        process.require_output_within_limits()
        try:
            process.process.wait(timeout=limits["shutdown_timeout_seconds"])
        except subprocess.TimeoutExpired as error:
            raise CheckFailure("authenticated shutdown did not terminate within its deadline") from error
    finally:
        exit_code, graceful = process.terminate(limits["shutdown_timeout_seconds"])

    require(graceful, "manager probe required SIGKILL")
    require(exit_code == 0, f"manager probe exited with code {exit_code}")
    require(not (probe_dir / "manager.pid").exists(), "manager PID file remained after shutdown")
    require(port_is_closed(port), "manager loopback port remained open after shutdown")
    stdout, _ = process.stdout.snapshot()
    stderr, _ = process.stderr.snapshot()
    missing_successes = sorted(set(EXPECTED_DIRECT_STATUSES) - success_semantics)
    uncovered_successes = [
        {
            "method": method,
            "path": path,
            "success_status": EXPECTED_SUCCESS_STATUSES[(method, path)],
            "observed_non_success_statuses": sorted(observed_statuses.get((method, path), set())),
            "reason": "The bounded runtime probe did not observe the declared success status.",
        }
        for method, path in missing_successes
    ]
    baseline_successes = {tuple(pair) for pair in EXPECTED_BASELINE_ROUTES}
    require(run_fixture is not None, "manager run fixture result is absent")
    return {
        "available": True,
        "mode": "temporary_home_loopback_process",
        "route_pairs_observed": [list(pair) for pair in sorted(observed_routes)],
        "run_fixture": run_fixture,
        "success_semantics": {
            "coverage_status": "partial" if uncovered_successes else "complete",
            "full_g10_compatibility_claimed": False if uncovered_successes else True,
            "expected_count": len(EXPECTED_ROUTE_SPECS),
            "exercised_count": len(success_semantics),
            "exercised": [list(pair) for pair in sorted(success_semantics)],
            "uncovered": uncovered_successes,
            "baseline_expected_count": len(baseline_successes),
            "baseline_exercised": [
                list(pair) for pair in sorted(baseline_successes & success_semantics)
            ],
            "baseline_complete": baseline_successes <= success_semantics,
        },
        "checks": [response_summary(case_id, result) for case_id, result in responses],
        "credential": {
            "format": "64_lowercase_hex",
            "permissions": "0600",
            "owner": "effective_user",
            "response_disclosure": False,
            "noncredential_scan": scan,
        },
        "process": {
            "exit_code": exit_code,
            "graceful_shutdown": graceful,
            "stdout_bytes": len(stdout),
            "stderr_bytes": len(stderr),
            "stdout_sha256": sha256_bytes(stdout),
            "stderr_sha256": sha256_bytes(stderr),
            "pid_file_removed": True,
            "port_closed": True,
        },
    }


def run_standalone_no_manager_probe(
    binary: pathlib.Path,
    probe_dir: pathlib.Path,
    contract: dict[str, Any],
) -> dict[str, Any]:
    limits = contract["limits"]
    port = reserve_loopback_port()
    write_probe_config(probe_dir, port)
    process = BoundedProcess(
        [
            str(binary),
            "dashboard",
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
            "--home",
            str(probe_dir),
        ],
        probe_environment(probe_dir),
        limits["maximum_process_stdout_bytes"],
        limits["maximum_process_stderr_bytes"],
    )
    result: HTTPResult | None = None
    exit_code: int | None = None
    graceful = False
    try:
        deadline = time.monotonic() + limits["startup_timeout_seconds"]
        while time.monotonic() < deadline:
            process.require_output_within_limits()
            if process.process.poll() is not None:
                raise CheckFailure(f"standalone dashboard exited before readiness with code {process.process.returncode}")
            try:
                candidate = request(
                    port,
                    "GET",
                    "/api/manager/status",
                    headers=None,
                    body=None,
                    timeout_seconds=1,
                    maximum_response_bytes=limits["maximum_response_bytes"],
                )
                if candidate.status == 503:
                    result = candidate
                    break
            except CheckFailure:
                pass
            time.sleep(0.05)
        require(result is not None, "standalone dashboard did not become ready within its deadline")
        require_exact_json(result, 503, contract["envelopes"]["no_manager"]["body"], contract, "no_manager")
    finally:
        exit_code, graceful = process.terminate(limits["shutdown_timeout_seconds"])
    require(graceful, "standalone dashboard required SIGKILL")
    require(exit_code == 0, f"standalone dashboard exited with code {exit_code}")
    require(port_is_closed(port), "standalone loopback port remained open after shutdown")
    require(result is not None, "standalone result is absent")
    stdout, _ = process.stdout.snapshot()
    stderr, _ = process.stderr.snapshot()
    return {
        "available": True,
        "check": response_summary("no_manager", result),
        "process": {
            "exit_code": exit_code,
            "graceful_shutdown": graceful,
            "stdout_bytes": len(stdout),
            "stderr_bytes": len(stderr),
            "stdout_sha256": sha256_bytes(stdout),
            "stderr_sha256": sha256_bytes(stderr),
            "port_closed": True,
        },
    }


def validate_binary(path: pathlib.Path, source_paths: list[pathlib.Path]) -> dict[str, Any]:
    require(path.is_file(), f"release binary is missing: {path}")
    require(not path.is_symlink(), "release binary must not be a symbolic link")
    require(os.access(path, os.X_OK), "release binary is not executable")
    metadata = path.stat()
    require(metadata.st_size > 0, "release binary is empty")
    newest_source = max(source.stat().st_mtime_ns for source in source_paths)
    require(metadata.st_mtime_ns >= newest_source, "release binary predates manager HTTP source")
    return {"sha256": digest(path), "bytes": metadata.st_size}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default=str(DEFAULT_BASELINE))
    parser.add_argument("--binary", default=str(DEFAULT_BINARY))
    parser.add_argument("--report", type=pathlib.Path)
    arguments = parser.parse_args()

    manifest_before = source_manifest(ROOT)
    baseline_path = resolve_repo_path(arguments.baseline)
    binary_path = resolve_repo_path(arguments.binary)
    contract = load_contract(baseline_path)
    source_result = validate_current_sources()
    source_paths = [ROOT / relative for relative in EXPECTED_BASELINE_SOURCE_SHA256]
    binary_result = validate_binary(binary_path, source_paths)

    with tempfile.TemporaryDirectory(prefix="forge-manager-http-p10-") as temporary_root:
        temporary_path = pathlib.Path(temporary_root)
        manager_result = run_manager_probe(binary_path, temporary_path / "manager", contract)
        standalone_result = run_standalone_no_manager_probe(
            binary_path,
            temporary_path / "standalone",
            contract,
        )

    coverage_status = manager_result["success_semantics"]["coverage_status"]
    full_compatibility = coverage_status == "complete"
    manifest_after = source_manifest(ROOT)
    require(manifest_before == manifest_after, "source/test/checker manifest changed during the probe")
    result = {
        "schema_version": 2,
        "ok": full_compatibility,
        "status": "passed" if full_compatibility else "partial",
        "phase": "P10",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "g10_compatibility_eligible": full_compatibility,
        "source_manifest": manifest_before,
        "baseline_revision": contract["baseline_revision"],
        "hashes": {
            "baseline_sha256": digest(baseline_path),
            "baseline_source_aggregate_sha256": contract["baseline_source_aggregate_sha256"],
            "binary_sha256": binary_result["sha256"],
            "current_source_aggregate_sha256": source_result["source_aggregate_sha256"],
            "current_source_sha256": source_result["source_sha256"],
        },
        "source": {
            "baseline_route_count": len(EXPECTED_BASELINE_ROUTES),
            "current_route_count": len(EXPECTED_ROUTE_SPECS),
            "route_pairs": source_result["route_pairs"],
            "public_route_pairs": source_result["public_route_pairs"],
            "protected_route_pairs": source_result["protected_route_pairs"],
            "direct_statuses": source_result["direct_statuses"],
            "baseline_routes_preserved": True,
        },
        "runtime": {
            "manager": manager_result,
            "standalone_no_manager": standalone_result,
            "persistent_evidence_written": arguments.report is not None,
            "install_or_deploy_invoked": False,
        },
    }
    if arguments.report is not None:
        report_path = resolve_repo_path(arguments.report)
        atomic_write_json(report_path, result)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if full_compatibility else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CheckFailure as error:
        print(json.dumps({"ok": False, "error": str(error)}, sort_keys=True), file=sys.stderr)
        raise SystemExit(1)
