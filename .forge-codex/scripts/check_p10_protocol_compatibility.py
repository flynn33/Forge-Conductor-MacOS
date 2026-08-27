#!/usr/bin/env python3
"""Assess executable MCP compatibility against the preserved P01 baseline."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import os
import pathlib
import selectors
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from typing import Any, Callable

from evidence_support import source_manifest


REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_BASELINE_TRANSCRIPT = (
    REPOSITORY_ROOT / ".forge-codex/evidence/EVID-20260823T184311Z-0dccfacc9f.stdout.txt"
)
DEFAULT_REQUESTS = REPOSITORY_ROOT / ".forge-codex/state/baseline/mcp-baseline-requests.ndjson"
SUPPORTED_PROTOCOL_VERSIONS = (
    "2025-11-25",
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
)
EXPECTED_METHODS = (
    "initialize",
    "notifications/initialized",
    "tools/list",
    "resources/list",
    "prompts/list",
    "ping",
)
EXPECTED_RESPONSE_IDS = (1, 2, 3, 4, 5)
EXPECTED_LEGACY_TOOL_COUNT = 34
EXPECTED_BASELINE_TRANSCRIPT_SHA256 = "332c4bc6124e9792eaf8d9aad109c79948ddff52f0cd56c228ad1abe01f4781b"
EXPECTED_REQUEST_FIXTURE_SHA256 = "3847873ebea36d3f0bf5f408cd1f72fad9fc45b948a68960b036f42072408d53"
MAXIMUM_MCP_MESSAGE_BYTES = 4 * 1024 * 1024
MAXIMUM_BUFFERED_RESPONSES = 16
MAXIMUM_BUFFERED_RESPONSE_BYTES = MAXIMUM_BUFFERED_RESPONSES * MAXIMUM_MCP_MESSAGE_BYTES


class CompatibilityError(RuntimeError):
    """Raised when an artifact or executable response cannot prove compatibility."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise CompatibilityError(message)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def normalized_hash(value: Any) -> str:
    return sha256_bytes(canonical_bytes(value))


def artifact(path: pathlib.Path) -> dict[str, Any]:
    try:
        display_path = path.resolve(strict=True).relative_to(REPOSITORY_ROOT).as_posix()
    except ValueError:
        display_path = str(path.resolve(strict=True))
    return {
        "path": display_path,
        "bytes": path.stat().st_size,
        "sha256": sha256_file(path),
    }


def load_ndjson(path: pathlib.Path, label: str) -> list[dict[str, Any]]:
    require(path.is_file(), f"{label} is missing: {path}")
    records: list[dict[str, Any]] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        require(line.strip() != "", f"{label} contains a blank line at {line_number}")
        try:
            record = json.loads(line)
        except (json.JSONDecodeError, ValueError) as error:
            raise CompatibilityError(f"{label} line {line_number} is not valid JSON: {error}") from error
        require(isinstance(record, dict), f"{label} line {line_number} is not an object")
        records.append(record)
    require(records, f"{label} is empty: {path}")
    return records


def validate_request_fixture(requests: list[dict[str, Any]]) -> None:
    methods = tuple(request.get("method") for request in requests)
    require(methods == EXPECTED_METHODS, f"request fixture methods changed: {methods}")
    response_ids: list[Any] = []
    for index, request in enumerate(requests, 1):
        require(request.get("jsonrpc") == "2.0", f"request {index} is not JSON-RPC 2.0")
        require(isinstance(request.get("params"), dict), f"request {index} params are malformed")
        if request["method"] == "notifications/initialized":
            require("id" not in request, "initialized notification unexpectedly has an id")
        else:
            require("id" in request, f"request {index} has no id")
            response_ids.append(request["id"])
    require(tuple(response_ids) == EXPECTED_RESPONSE_IDS, f"request fixture ids changed: {response_ids}")
    initialize = requests[0]["params"]
    require(isinstance(initialize.get("protocolVersion"), str), "initialize protocolVersion is missing")
    require(isinstance(initialize.get("capabilities"), dict), "initialize capabilities are malformed")


def response_map(responses: list[dict[str, Any]], label: str) -> dict[Any, dict[str, Any]]:
    by_id: dict[Any, dict[str, Any]] = {}
    for index, response in enumerate(responses, 1):
        require(response.get("jsonrpc") == "2.0", f"{label} response {index} is not JSON-RPC 2.0")
        require("id" in response, f"{label} response {index} has no id")
        request_id = response["id"]
        require(request_id not in by_id, f"{label} has duplicate response id {request_id!r}")
        require("error" not in response, f"{label} response {request_id!r} is an error: {response.get('error')}")
        require(isinstance(response.get("result"), dict), f"{label} response {request_id!r} has no result object")
        by_id[request_id] = response
    require(tuple(by_id) == EXPECTED_RESPONSE_IDS, f"{label} response ids changed: {tuple(by_id)}")
    return by_id


def tool_map(response: dict[str, Any], label: str) -> dict[str, dict[str, Any]]:
    result = response.get("result")
    require(isinstance(result, dict), f"{label} tools/list result is malformed")
    descriptors = result.get("tools")
    require(isinstance(descriptors, list), f"{label} tools/list result has no tools array")
    tools: dict[str, dict[str, Any]] = {}
    for index, descriptor in enumerate(descriptors, 1):
        require(isinstance(descriptor, dict), f"{label} tool descriptor {index} is malformed")
        name = descriptor.get("name")
        require(isinstance(name, str) and name.strip() == name and name, f"{label} tool {index} has an invalid name")
        require(name not in tools, f"{label} has duplicate tool {name!r}")
        require(isinstance(descriptor.get("description"), str), f"{label} tool {name!r} has no description")
        require(descriptor["description"].strip() != "", f"{label} tool {name!r} has a blank description")
        require(
            isinstance(descriptor.get("inputSchema"), (dict, bool)),
            f"{label} tool {name!r} has no JSON input schema",
        )
        tools[name] = descriptor
    return tools


def normalize_description(value: str) -> str:
    return " ".join(value.split())


def decimal_value(value: Any, path: str) -> Decimal:
    require(not isinstance(value, bool), f"{path} must be numeric")
    try:
        parsed = Decimal(str(value))
    except (InvalidOperation, ValueError) as error:
        raise CompatibilityError(f"{path} must be numeric") from error
    require(parsed.is_finite(), f"{path} must be finite")
    return parsed


def type_set(schema: dict[str, Any], path: str) -> set[str] | None:
    raw = schema.get("type")
    if raw is None:
        return None
    values = [raw] if isinstance(raw, str) else raw
    require(isinstance(values, list) and values, f"{path}.type is malformed")
    require(all(isinstance(item, str) and item for item in values), f"{path}.type is malformed")
    result = set(values)
    require(len(result) == len(values), f"{path}.type contains duplicates")
    return result


def compare_lower_bound(
    baseline: dict[str, Any],
    current: dict[str, Any],
    path: str,
) -> list[str]:
    def lower(schema: dict[str, Any], side: str) -> tuple[Decimal, bool] | None:
        candidates: list[tuple[Decimal, bool]] = []
        if "minimum" in schema:
            candidates.append((decimal_value(schema["minimum"], f"{path}.{side}.minimum"), False))
        if "exclusiveMinimum" in schema:
            raw = schema["exclusiveMinimum"]
            require(not isinstance(raw, bool), f"{path}.{side}.exclusiveMinimum uses an unsupported boolean form")
            candidates.append((decimal_value(raw, f"{path}.{side}.exclusiveMinimum"), True))
        return max(candidates, key=lambda item: (item[0], item[1])) if candidates else None

    old = lower(baseline, "baseline")
    new = lower(current, "current")
    if old is None and new is not None:
        return [f"{path}: added lower bound {new[0]}"]
    if old is None or new is None:
        return []
    if new[0] > old[0] or (new[0] == old[0] and new[1] and not old[1]):
        return [f"{path}: lower bound narrowed from {old} to {new}"]
    return []


def compare_upper_bound(
    baseline: dict[str, Any],
    current: dict[str, Any],
    path: str,
) -> list[str]:
    def upper(schema: dict[str, Any], side: str) -> tuple[Decimal, bool] | None:
        candidates: list[tuple[Decimal, bool]] = []
        if "maximum" in schema:
            candidates.append((decimal_value(schema["maximum"], f"{path}.{side}.maximum"), False))
        if "exclusiveMaximum" in schema:
            raw = schema["exclusiveMaximum"]
            require(not isinstance(raw, bool), f"{path}.{side}.exclusiveMaximum uses an unsupported boolean form")
            candidates.append((decimal_value(raw, f"{path}.{side}.exclusiveMaximum"), True))
        return min(candidates, key=lambda item: (item[0], not item[1])) if candidates else None

    old = upper(baseline, "baseline")
    new = upper(current, "current")
    if old is None and new is not None:
        return [f"{path}: added upper bound {new[0]}"]
    if old is None or new is None:
        return []
    if new[0] < old[0] or (new[0] == old[0] and new[1] and not old[1]):
        return [f"{path}: upper bound narrowed from {old} to {new}"]
    return []


def compare_minimum_keyword(
    keyword: str,
    baseline: dict[str, Any],
    current: dict[str, Any],
    path: str,
) -> list[str]:
    if keyword not in baseline and keyword in current:
        return [f"{path}: added {keyword}={current[keyword]!r}"]
    if keyword not in baseline or keyword not in current:
        return []
    old = decimal_value(baseline[keyword], f"{path}.baseline.{keyword}")
    new = decimal_value(current[keyword], f"{path}.current.{keyword}")
    return [f"{path}: {keyword} narrowed from {old} to {new}"] if new > old else []


def compare_maximum_keyword(
    keyword: str,
    baseline: dict[str, Any],
    current: dict[str, Any],
    path: str,
) -> list[str]:
    if keyword not in baseline and keyword in current:
        return [f"{path}: added {keyword}={current[keyword]!r}"]
    if keyword not in baseline or keyword not in current:
        return []
    old = decimal_value(baseline[keyword], f"{path}.baseline.{keyword}")
    new = decimal_value(current[keyword], f"{path}.current.{keyword}")
    return [f"{path}: {keyword} narrowed from {old} to {new}"] if new < old else []


def compare_schema(baseline: Any, current: Any, path: str) -> list[str]:
    """Return conservative proof failures when current may reject a baseline-valid value."""
    if isinstance(baseline, bool):
        if baseline is False:
            return []
        return [] if current is True else [f"{path}: unconstrained true schema became constrained"]
    if isinstance(current, bool):
        return [] if current is True else [f"{path}: schema became false"]
    require(isinstance(baseline, dict), f"{path}: baseline schema is malformed")
    require(isinstance(current, dict), f"{path}: current schema is malformed")

    known_keywords = {
        "$anchor", "$comment", "$defs", "$id", "$ref", "$schema",
        "additionalItems", "additionalProperties", "allOf", "anyOf", "const",
        "contains", "contentEncoding", "contentMediaType", "default", "definitions",
        "dependentRequired", "dependentSchemas", "dependencies", "deprecated", "description",
        "else", "enum", "examples", "exclusiveMaximum", "exclusiveMinimum", "format",
        "if", "items", "maxContains", "maximum", "maxItems", "maxLength", "maxProperties",
        "minContains", "minimum", "minItems", "minLength", "minProperties", "multipleOf",
        "not", "oneOf", "pattern", "patternProperties", "prefixItems", "properties",
        "propertyNames", "readOnly", "required", "then", "title", "type",
        "unevaluatedItems", "unevaluatedProperties", "uniqueItems", "writeOnly",
    }
    unknown = (set(baseline) | set(current)) - known_keywords
    require(not unknown, f"{path}: unsupported schema keywords prevent proof: {sorted(unknown)}")

    problems: list[str] = []
    old_types = type_set(baseline, f"{path}.baseline")
    new_types = type_set(current, f"{path}.current")
    if old_types is None and new_types is not None:
        problems.append(f"{path}: added type constraint {sorted(new_types)}")
    elif old_types is not None and new_types is not None and not old_types <= new_types:
        problems.append(f"{path}: types narrowed from {sorted(old_types)} to {sorted(new_types)}")

    if "description" in baseline:
        old_description = baseline["description"]
        new_description = current.get("description")
        if not isinstance(old_description, str) or not isinstance(new_description, str):
            problems.append(f"{path}: schema description was removed or malformed")
        elif normalize_description(old_description) != normalize_description(new_description):
            problems.append(f"{path}: schema description changed")

    if "enum" in baseline:
        old_enum = baseline["enum"]
        new_enum = current.get("enum")
        if not isinstance(old_enum, list) or not isinstance(new_enum, list):
            problems.append(f"{path}: enum was removed or malformed")
        else:
            missing = [item for item in old_enum if item not in new_enum]
            if missing:
                problems.append(f"{path}: enum removed values {missing!r}")
    elif "enum" in current:
        problems.append(f"{path}: added enum constraint")

    if "const" in baseline:
        if current.get("const", object()) != baseline["const"]:
            problems.append(f"{path}: const was removed or changed")
    elif "const" in current:
        problems.append(f"{path}: added const constraint")

    old_required = baseline.get("required", [])
    new_required = current.get("required", [])
    require(
        isinstance(old_required, list) and all(isinstance(item, str) for item in old_required),
        f"{path}: baseline required is malformed",
    )
    require(
        isinstance(new_required, list) and all(isinstance(item, str) for item in new_required),
        f"{path}: current required is malformed",
    )
    added_required = sorted(set(new_required) - set(old_required))
    if added_required:
        problems.append(f"{path}: added required properties {added_required}")

    old_properties = baseline.get("properties", {})
    new_properties = current.get("properties", {})
    require(isinstance(old_properties, dict), f"{path}: baseline properties are malformed")
    require(isinstance(new_properties, dict), f"{path}: current properties are malformed")
    for name, old_property in old_properties.items():
        if name not in new_properties:
            problems.append(f"{path}: removed property schema {name!r}")
        else:
            problems.extend(compare_schema(old_property, new_properties[name], f"{path}.properties.{name}"))

    old_additional = baseline.get("additionalProperties", True)
    new_additional = current.get("additionalProperties", True)
    if old_additional is not False:
        if new_additional is False:
            problems.append(f"{path}: additionalProperties became false")
        elif isinstance(old_additional, (dict, bool)) and isinstance(new_additional, (dict, bool)):
            problems.extend(compare_schema(old_additional, new_additional, f"{path}.additionalProperties"))
        else:
            raise CompatibilityError(f"{path}: additionalProperties is malformed")

    problems.extend(compare_lower_bound(baseline, current, path))
    problems.extend(compare_upper_bound(baseline, current, path))
    for keyword in ("minLength", "minItems", "minProperties", "minContains"):
        problems.extend(compare_minimum_keyword(keyword, baseline, current, path))
    for keyword in ("maxLength", "maxItems", "maxProperties", "maxContains"):
        problems.extend(compare_maximum_keyword(keyword, baseline, current, path))

    if "multipleOf" in baseline:
        if "multipleOf" in current:
            old_multiple = decimal_value(baseline["multipleOf"], f"{path}.baseline.multipleOf")
            new_multiple = decimal_value(current["multipleOf"], f"{path}.current.multipleOf")
            require(old_multiple > 0 and new_multiple > 0, f"{path}: multipleOf must be positive")
            quotient = old_multiple / new_multiple
            if quotient != quotient.to_integral_value():
                problems.append(f"{path}: multipleOf narrowed from {old_multiple} to {new_multiple}")
    elif "multipleOf" in current:
        problems.append(f"{path}: added multipleOf constraint")

    for keyword in ("pattern", "format", "contentEncoding", "contentMediaType", "$ref"):
        if keyword not in baseline and keyword in current:
            problems.append(f"{path}: added {keyword} constraint")
        elif keyword in baseline and keyword in current and baseline[keyword] != current[keyword]:
            problems.append(f"{path}: {keyword} changed")

    old_unique = baseline.get("uniqueItems", False)
    new_unique = current.get("uniqueItems", False)
    require(isinstance(old_unique, bool) and isinstance(new_unique, bool), f"{path}: uniqueItems is malformed")
    if not old_unique and new_unique:
        problems.append(f"{path}: uniqueItems became true")

    if "items" not in baseline and "items" in current:
        problems.append(f"{path}: added items constraint")
    elif "items" in baseline and "items" in current:
        old_items = baseline["items"]
        new_items = current["items"]
        if isinstance(old_items, list) or isinstance(new_items, list):
            if canonical_bytes(old_items) != canonical_bytes(new_items):
                problems.append(f"{path}: tuple items changed and cannot be proven non-narrowing")
        else:
            problems.extend(compare_schema(old_items, new_items, f"{path}.items"))

    for keyword in (
        "allOf", "anyOf", "oneOf", "not", "if", "then", "else", "contains",
        "prefixItems", "patternProperties", "propertyNames", "dependentRequired",
        "dependentSchemas", "dependencies", "additionalItems", "unevaluatedItems",
        "unevaluatedProperties", "$defs", "definitions",
    ):
        old_has = keyword in baseline
        new_has = keyword in current
        if not old_has and new_has:
            problems.append(f"{path}: added complex constraint {keyword}")
        elif old_has and new_has and canonical_bytes(baseline[keyword]) != canonical_bytes(current[keyword]):
            problems.append(f"{path}: complex constraint {keyword} changed and cannot be proven non-narrowing")

    return problems


class MCPProcess:
    def __init__(self, binary: pathlib.Path, home: pathlib.Path, probe_label: str) -> None:
        environment = dict(os.environ)
        for key in (
            "FORGE_OPERATOR_UI_TEST_PORT",
            "FORGE_RUNTIME_LIMIT_CORE_BYTES",
            "FORGE_RUNTIME_LIMIT_CPU_SECONDS",
            "FORGE_RUNTIME_LIMIT_FILE_BYTES",
            "FORGE_RUNTIME_LIMIT_OPEN_FILES",
        ):
            environment.pop(key, None)
        environment.update(
            FORGE_CONDUCTOR_HOME=str(home),
            FORGE_DEPLOYMENT_ID=f"p10-protocol-{probe_label}",
            FORGE_MCP_ROLE="primary",
            FORGE_SKIP_PS="1",
        )
        self.stderr_file = tempfile.TemporaryFile(mode="w+b")
        self.process = subprocess.Popen(
            [str(binary), "serve"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.stderr_file,
            env=environment,
            bufsize=0,
        )
        require(self.process.stdout is not None, "MCP stdout is unavailable")
        self._stdout_buffer = bytearray()
        self._stdout_descriptor = self.process.stdout.fileno()
        self._pending_responses: list[tuple[dict[str, Any], int]] = []
        self._pending_response_bytes = 0
        self._response_arrival_ids: list[Any] = []
        os.set_blocking(self._stdout_descriptor, False)

    def send(self, request: dict[str, Any]) -> None:
        self.send_raw(canonical_bytes(request).decode("utf-8") + "\n")

    def send_raw(self, value: str) -> None:
        require(self.process.stdin is not None, "MCP stdin is unavailable")
        self.process.stdin.write(value.encode("utf-8"))
        self.process.stdin.flush()

    def _take_response_line(self, method: str) -> bytes | None:
        newline = self._stdout_buffer.find(b"\n")
        if newline >= 0:
            require(
                newline <= MAXIMUM_MCP_MESSAGE_BYTES,
                f"server MCP message exceeded {MAXIMUM_MCP_MESSAGE_BYTES} bytes while waiting for {method}",
            )
            line = bytes(self._stdout_buffer[:newline])
            del self._stdout_buffer[:newline + 1]
            return line
        require(
            len(self._stdout_buffer) <= MAXIMUM_MCP_MESSAGE_BYTES,
            f"server MCP message exceeded {MAXIMUM_MCP_MESSAGE_BYTES} bytes while waiting for {method}",
        )
        return None

    def receive(self, expected_id: Any, method: str, timeout: float) -> dict[str, Any]:
        require(self.process.stdout is not None, "MCP stdout is unavailable")
        expected_key = self._response_id_key(expected_id)
        for index, (response, encoded_bytes) in enumerate(self._pending_responses):
            require("id" in response, f"buffered response for {method} has no id")
            if self._response_id_key(response["id"]) == expected_key:
                self._pending_responses.pop(index)
                self._pending_response_bytes -= encoded_bytes
                return response

        selector = selectors.DefaultSelector()
        selector.register(self._stdout_descriptor, selectors.EVENT_READ)
        deadline = time.monotonic() + timeout
        try:
            while True:
                line = self._take_response_line(method)
                if line is not None:
                    require(line.strip() != b"", f"server emitted a blank line while waiting for {method}")
                    try:
                        response = json.loads(line)
                    except (json.JSONDecodeError, UnicodeDecodeError, ValueError) as error:
                        raise CompatibilityError(f"server emitted malformed JSON for {method}: {error}") from error
                    require(isinstance(response, dict), f"server emitted a non-object response for {method}")
                    require("id" in response, f"server emitted a response without an id for {method}")
                    response_id = response["id"]
                    self._response_arrival_ids.append(response_id)
                    if self._response_id_key(response_id) == expected_key:
                        return response
                    require(
                        len(self._pending_responses) < MAXIMUM_BUFFERED_RESPONSES,
                        f"server exceeded {MAXIMUM_BUFFERED_RESPONSES} buffered responses while waiting for {method}",
                    )
                    encoded_bytes = len(line) + 1
                    require(
                        self._pending_response_bytes + encoded_bytes
                        <= MAXIMUM_BUFFERED_RESPONSE_BYTES,
                        "server exceeded the buffered response byte limit",
                    )
                    self._pending_responses.append((response, encoded_bytes))
                    self._pending_response_bytes += encoded_bytes
                    continue

                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise CompatibilityError(self.failure(f"timed out waiting for {method}"))
                if not selector.select(min(0.1, remaining)):
                    if self.process.poll() is not None:
                        raise CompatibilityError(self.failure(f"server exited while waiting for {method}"))
                    continue
                try:
                    maximum_read = min(
                        64 * 1024,
                        MAXIMUM_MCP_MESSAGE_BYTES + 1 - len(self._stdout_buffer),
                    )
                    chunk = os.read(self._stdout_descriptor, maximum_read)
                except BlockingIOError:
                    continue
                require(chunk != b"", self.failure(f"server closed stdout while waiting for {method}"))
                self._stdout_buffer.extend(chunk)
        finally:
            selector.close()

    def finish(self, timeout: float) -> tuple[bytes, bytes, int]:
        if self.process.stdin and not self.process.stdin.closed:
            try:
                self.process.stdin.close()
            except BrokenPipeError:
                pass
        try:
            return_code = self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
            raise CompatibilityError("MCP server did not stop after stdin closed") from error
        require(self.process.stdout is not None, "MCP stdout is unavailable at shutdown")
        buffered_responses = b"".join(
            canonical_bytes(response) + b"\n"
            for response, _ in self._pending_responses
        )
        trailing = buffered_responses + bytes(self._stdout_buffer) + (self.process.stdout.read() or b"")
        self._pending_responses.clear()
        self._pending_response_bytes = 0
        self._stdout_buffer.clear()
        self.process.stdout.close()
        self.stderr_file.seek(0)
        stderr = self.stderr_file.read()
        self.stderr_file.close()
        return trailing, stderr, return_code

    def close(self, timeout: float) -> tuple[bytes, int]:
        trailing, stderr, return_code = self.finish(timeout)
        require(not trailing.strip(), f"server emitted unexpected trailing stdout: {trailing[:500]!r}")
        return stderr, return_code

    def abort(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
        for stream in (self.process.stdin, self.process.stdout):
            if stream and not stream.closed:
                stream.close()
        if not self.stderr_file.closed:
            self.stderr_file.close()

    def failure(self, message: str) -> str:
        self.stderr_file.flush()
        position = self.stderr_file.tell()
        self.stderr_file.seek(0)
        stderr = self.stderr_file.read().decode("utf-8", errors="replace")[-2000:]
        self.stderr_file.seek(position)
        return f"{message}; stderr={stderr}"

    @property
    def response_arrival_ids(self) -> list[Any]:
        return list(self._response_arrival_ids)

    @staticmethod
    def _response_id_key(value: Any) -> tuple[str, bytes]:
        return (type(value).__name__, canonical_bytes(value))


def validate_endpoint_response(response: dict[str, Any], method: str, expected_id: Any) -> None:
    require(response.get("jsonrpc") == "2.0", f"{method} response is not JSON-RPC 2.0")
    require(response.get("id") == expected_id, f"{method} response id does not match")
    require("error" not in response, f"{method} returned an error: {response.get('error')}")
    require(isinstance(response.get("result"), dict), f"{method} has no result object")
    result = response["result"]
    if method == "initialize":
        require(isinstance(result.get("protocolVersion"), str), "initialize has no protocolVersion")
        require(isinstance(result.get("capabilities"), dict), "initialize capabilities are malformed")
        require(isinstance(result.get("serverInfo"), dict), "initialize serverInfo is malformed")
        require(isinstance(result["serverInfo"].get("name"), str), "initialize server name is missing")
        require(isinstance(result["serverInfo"].get("version"), str), "initialize server version is missing")
    elif method == "tools/list":
        require(isinstance(result.get("tools"), list), "tools/list has no tools array")
    elif method == "resources/list":
        require(isinstance(result.get("resources"), list), "resources/list has no resources array")
    elif method == "prompts/list":
        require(isinstance(result.get("prompts"), list), "prompts/list has no prompts array")
    elif method == "ping":
        require(result == {}, f"ping result changed: {result!r}")


def stream_artifact(value: bytes, *, include_tail: bool = False) -> dict[str, Any]:
    result: dict[str, Any] = {
        "bytes": len(value),
        "sha256": sha256_bytes(value),
    }
    if include_tail:
        result["utf8_tail"] = value.decode("utf-8", errors="replace")[-1000:]
    return result


def ndjson_artifact(requests: list[dict[str, Any]]) -> dict[str, Any]:
    data = b"".join(canonical_bytes(request) + b"\n" for request in requests)
    return {
        "framing": "ndjson",
        "bytes": len(data),
        "sha256": sha256_bytes(data),
    }


def seal_probe(probe: dict[str, Any]) -> dict[str, Any]:
    probe["normalized_probe_payload_sha256"] = normalized_hash(probe)
    return probe


def initialize_process(
    binary: pathlib.Path,
    home: pathlib.Path,
    probe_label: str,
    response_timeout: float,
) -> tuple[MCPProcess, list[dict[str, Any]], list[dict[str, Any]]]:
    process = MCPProcess(binary, home, probe_label)
    initialize = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": SUPPORTED_PROTOCOL_VERSIONS[0],
            "capabilities": {},
            "clientInfo": {"name": "forge-p10-wire-probe", "version": "1"},
        },
    }
    initialized = {
        "jsonrpc": "2.0",
        "method": "notifications/initialized",
        "params": {},
    }
    requests = [initialize, initialized]
    responses: list[dict[str, Any]] = []
    try:
        process.send(initialize)
        response = process.receive(1, "initialize", response_timeout)
        validate_endpoint_response(response, "initialize", 1)
        require(
            response["result"]["protocolVersion"] == SUPPORTED_PROTOCOL_VERSIONS[0],
            f"{probe_label} initialize negotiated the wrong protocol",
        )
        responses.append(response)
        process.send(initialized)
        return process, requests, responses
    except BaseException:
        process.abort()
        raise


def validate_rpc_error(response: dict[str, Any], expected_id: Any, expected_code: int) -> None:
    require(response.get("jsonrpc") == "2.0", "JSON-RPC error response has the wrong version")
    require(response.get("id") == expected_id, "JSON-RPC error response has the wrong id")
    require("result" not in response, "JSON-RPC error response unexpectedly contains a result")
    error = response.get("error")
    require(isinstance(error, dict), "JSON-RPC error response has no error object")
    require(error.get("code") == expected_code, f"JSON-RPC error code changed: {error.get('code')!r}")
    require(isinstance(error.get("message"), str) and error["message"], "JSON-RPC error message is missing")


def validate_tool_call_envelope(
    response: dict[str, Any],
    *,
    expected_error: bool,
    expected_code: str | None = None,
    expected_id: Any = 2,
) -> dict[str, Any]:
    require(response.get("jsonrpc") == "2.0", "tools/call response has the wrong JSON-RPC version")
    require(response.get("id") == expected_id, "tools/call response has the wrong id")
    require("error" not in response, "tools/call returned a transport-level error")
    result = response.get("result")
    require(isinstance(result, dict), "tools/call result is malformed")
    require(result.get("isError") is expected_error, "tools/call isError does not match the payload")
    structured = result.get("structuredContent")
    require(isinstance(structured, dict), "tools/call structuredContent is malformed")
    require(structured.get("ok") is (not expected_error), "tools/call structured ok flag is inconsistent")
    content = result.get("content")
    require(isinstance(content, list) and len(content) == 1, "tools/call content envelope changed")
    first = content[0]
    require(isinstance(first, dict) and first.get("type") == "text", "tools/call text content is malformed")
    text_value = first.get("text")
    require(isinstance(text_value, str), "tools/call text payload is missing")
    try:
        decoded = json.loads(text_value)
    except (json.JSONDecodeError, ValueError) as error:
        raise CompatibilityError(f"tools/call text payload is not JSON: {error}") from error
    require(decoded == structured, "tools/call text and structured payloads disagree")
    if expected_code is not None:
        require(structured.get("code") == expected_code, f"typed tool error code changed: {structured.get('code')!r}")
        require(isinstance(structured.get("message"), str) and structured["message"], "typed tool error message is missing")
        require(isinstance(structured.get("retryable"), bool), "typed tool error retryable flag is missing")
    return structured


def validate_typed_error_response(response: dict[str, Any]) -> None:
    validate_tool_call_envelope(response, expected_error=True, expected_code="invalid_key")


def exercise_initialized_probe(
    binary: pathlib.Path,
    root: pathlib.Path,
    name: str,
    target: dict[str, Any],
    validator: Callable[[dict[str, Any]], None],
    checks: list[str],
    response_timeout: float,
    shutdown_timeout: float,
    before_target: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    home = root / name
    home.mkdir(parents=True, exist_ok=False)
    process, requests, responses = initialize_process(binary, home, name, response_timeout)
    try:
        for notification in before_target or []:
            require("id" not in notification, f"{name} setup message must be a notification")
            requests.append(notification)
            process.send(notification)
        require(target.get("id") == 2, f"{name} target must use id 2")
        requests.append(target)
        process.send(target)
        response = process.receive(2, target.get("method", name), response_timeout)
        validator(response)
        responses.append(response)
        stderr, return_code = process.close(shutdown_timeout)
        require(return_code == 0, f"{name} server exited {return_code}")
    except BaseException:
        process.abort()
        raise
    return seal_probe({
        "name": name,
        "status": "passed",
        "checks": checks,
        "wire_input": ndjson_artifact(requests),
        "requests": requests,
        "responses": responses,
        "exit_codes": [return_code],
        "stderr": [stream_artifact(stderr)],
    })


def stop_failed_process(process: MCPProcess, timeout: float) -> None:
    if process.process.poll() is not None:
        process.abort()
        return
    try:
        process.finish(max(0.1, timeout))
    except BaseException:
        process.abort()


def prepare_tool_fixture(
    home: pathlib.Path,
    tool_names: list[str],
) -> tuple[pathlib.Path, pathlib.Path, str]:
    require(tool_names, "tool fixture requires at least one granted tool")
    require(len(tool_names) == len(set(tool_names)), "tool fixture grants contain duplicates")
    require(
        all(
            tool
            and all(character.isalnum() or character in "._-" for character in tool)
            for tool in tool_names
        ),
        "tool fixture grant contains an invalid tool name",
    )

    agents = home / "agents"
    workspace = home / "fixture-project"
    agents.mkdir(parents=True, exist_ok=False)
    workspace.mkdir(parents=True, exist_ok=False)
    playbook = agents / "compatibility-fixture.md"
    playbook.write_text(
        "\n".join([
            "---",
            "id: compatibility-fixture",
            "display_name: Compatibility Fixture",
            "description: Isolated protocol fixture.",
            f"tools: [{', '.join(tool_names)}]",
            "output_schema: [result]",
            "---",
            "",
            "# Compatibility fixture",
            "",
            "Use only for the isolated protocol matrix.",
            "",
        ]),
        encoding="utf-8",
    )

    tracked = workspace / "tracked.txt"
    tracked.write_text("tracked before\n", encoding="utf-8")
    git_commands = (
        ["git", "init", "--quiet"],
        ["git", "config", "user.name", "Forge Fixture"],
        ["git", "config", "user.email", "fixture@forge.invalid"],
        ["git", "add", "tracked.txt"],
        ["git", "commit", "--quiet", "-m", "Seed compatibility fixture"],
    )
    for command in git_commands:
        result = subprocess.run(
            command,
            cwd=workspace,
            capture_output=True,
            text=True,
            timeout=15,
        )
        require(
            result.returncode == 0,
            f"tool fixture setup failed for {command[:2]}: {result.stderr[-1000:]}",
        )
    initial_head = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=workspace,
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout.strip()
    require(len(initial_head) == 40, "tool fixture initial Git revision is malformed")
    return workspace, playbook, initial_head


def exercise_legacy_tool_success_matrix(
    binary: pathlib.Path,
    root: pathlib.Path,
    legacy_tools: list[str],
    response_timeout: float,
    shutdown_timeout: float,
) -> dict[str, Any]:
    name = "legacy_tool_success_matrix"
    require(
        len(legacy_tools) == EXPECTED_LEGACY_TOOL_COUNT,
        "legacy tool matrix does not contain the preserved tool count",
    )
    home = root / name
    home.mkdir(parents=True, exist_ok=False)
    workspace, playbook, initial_head = prepare_tool_fixture(home, legacy_tools)
    tracked = workspace / "tracked.txt"
    source = workspace / "source.md"
    moved = workspace / "moved.md"
    delete_target = workspace / "delete-me"
    converted_pdf = workspace / "from-file.pdf"
    direct_pdf = workspace / "direct.pdf"
    process, requests, responses = initialize_process(binary, home, name, response_timeout)
    called_tools: list[str] = []

    def call_tool(tool_name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        request_id = len(called_tools) + 2
        request = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "tools/call",
            "params": {"name": tool_name, "arguments": arguments},
        }
        requests.append(request)
        process.send(request)
        response = process.receive(request_id, tool_name, response_timeout)
        structured = validate_tool_call_envelope(
            response,
            expected_error=False,
            expected_id=request_id,
        )
        responses.append(response)
        called_tools.append(tool_name)
        return structured

    try:
        started = call_tool(
            "agent_run_start",
            {
                "agent_id": "compatibility-fixture",
                "goal": "Exercise preserved tool behavior",
                "cwd": str(workspace),
            },
        )
        session_id = started.get("session_id")
        project_id = started.get("project_id")
        require(isinstance(session_id, str) and session_id, "agent_run_start returned no session id")
        require(isinstance(project_id, str), "agent_run_start returned no project id")
        try:
            uuid.UUID(project_id)
        except (ValueError, AttributeError) as error:
            raise CompatibilityError("agent_run_start returned an invalid project id") from error
        project_context = started.get("project_context")
        require(isinstance(project_context, dict), "agent_run_start returned no project context")
        require(project_context.get("project_id") == project_id, "agent project context id changed")
        require(
            project_context.get("project_generation") == started.get("project_generation"),
            "agent project generation is inconsistent",
        )
        roots = project_context.get("authorization_roots")
        require(
            isinstance(roots, list)
            and any(
                isinstance(root, str)
                and pathlib.Path(root).exists()
                and os.path.samefile(root, workspace)
                for root in roots
            ),
            "workspace authorization root is missing",
        )

        status = call_tool("forge_status", {})
        status_tools = status.get("tools")
        require(isinstance(status_tools, list), "forge_status returned no tool inventory")
        require(set(legacy_tools).issubset(status_tools), "forge_status omitted preserved legacy tools")

        agents = call_tool("agent_list", {}).get("agents")
        require(isinstance(agents, list), "agent_list returned no agents")
        require(
            any(isinstance(agent, dict) and agent.get("id") == "compatibility-fixture" for agent in agents),
            "agent_list omitted the isolated fixture",
        )
        agent = call_tool("agent_get", {"agent_id": "compatibility-fixture"})
        require(agent.get("id") == "compatibility-fixture", "agent_get returned the wrong agent")
        context = call_tool("agent_context", {"agent_id": "compatibility-fixture"})
        require(context.get("id") == "compatibility-fixture", "agent_context returned the wrong agent")
        require(isinstance(context.get("body"), str) and context["body"], "agent_context returned no playbook body")
        recommendation = call_tool("agent_recommend", {"task": "implement compatibility fixture"})
        require(isinstance(recommendation.get("agent_id"), str), "agent_recommend returned no agent id")
        run_status = call_tool("agent_run_status", {"session_id": session_id})
        session = run_status.get("session")
        require(isinstance(session, dict) and session.get("id") == session_id, "agent_run_status lost its session")
        require(run_status.get("must_complete") is True, "active agent session was not marked incomplete")

        created = call_tool("fs_mkdir", {"path": str(delete_target)})
        require(created.get("path") == str(delete_target), "fs_mkdir returned the wrong path")
        require(delete_target.is_dir(), "fs_mkdir did not create its directory")
        source_text = "# Fixture\nlegacy matrix needle\n"
        written = call_tool("fs_write", {"path": str(source), "content": source_text})
        require(written.get("bytes_written") == len(source_text.encode()), "fs_write byte count changed")
        require(source.read_text(encoding="utf-8") == source_text, "fs_write did not persist exact content")
        read = call_tool("fs_read", {"path": str(source)})
        require(read.get("content") == source_text, "fs_read did not return exact content")
        edited = call_tool(
            "fs_edit",
            {"path": str(tracked), "old": "tracked before", "new": "tracked after"},
        )
        require(edited.get("replacements") == 1, "fs_edit replacement count changed")
        require(tracked.read_text(encoding="utf-8") == "tracked after\n", "fs_edit did not persist its edit")
        listed = call_tool("fs_list", {"path": str(workspace)})
        entries = listed.get("entries")
        require(isinstance(entries, list) and "source.md" in entries, "fs_list omitted the fixture file")
        globbed = call_tool("fs_glob", {"path": str(workspace), "pattern": "*.md"})
        matches = globbed.get("matches")
        require(isinstance(matches, list) and str(source) in matches, "fs_glob omitted the fixture file")
        searched = call_tool("search_text", {"path": str(workspace), "pattern": "legacy matrix needle"})
        search_matches = searched.get("matches")
        require(
            searched.get("count") == 1
            and isinstance(search_matches, list)
            and any("source.md:2:legacy matrix needle" in match for match in search_matches),
            "search_text did not return the exact fixture match",
        )

        converted = call_tool(
            "pdf_from_file",
            {"source_path": str(source), "dest_path": str(converted_pdf), "title": "Fixture"},
        )
        require(converted.get("source_path") == str(source), "pdf_from_file source path changed")
        require(converted.get("path") == str(converted_pdf), "pdf_from_file destination path changed")
        require(converted.get("bytes_written", 0) > 0 and converted.get("pages", 0) > 0, "pdf_from_file is empty")
        require(converted_pdf.read_bytes().startswith(b"%PDF-"), "pdf_from_file did not create a PDF")
        direct = call_tool(
            "pdf_write",
            {"path": str(direct_pdf), "content": "# Direct\nFixture body", "title": "Fixture"},
        )
        require(direct.get("path") == str(direct_pdf), "pdf_write destination path changed")
        require(direct.get("bytes_written", 0) > 0 and direct.get("pages", 0) > 0, "pdf_write is empty")
        require(direct_pdf.read_bytes().startswith(b"%PDF-"), "pdf_write did not create a PDF")
        move = call_tool("fs_move", {"source": str(source), "destination": str(moved)})
        require(move.get("src") == str(source) and move.get("dest") == str(moved), "fs_move paths changed")
        require(not source.exists() and moved.read_text(encoding="utf-8") == source_text, "fs_move lost fixture content")
        deleted = call_tool("fs_delete", {"path": str(delete_target)})
        require(deleted.get("deleted") is True and not delete_target.exists(), "fs_delete did not remove its target")

        git_status = call_tool("git_status", {"cwd": str(workspace)})
        require(git_status.get("exit_code") == 0, "git_status failed")
        require("tracked.txt" in git_status.get("stdout", ""), "git_status omitted the tracked edit")
        git_diff = call_tool("git_diff", {"cwd": str(workspace)})
        require(git_diff.get("exit_code") == 0, "git_diff failed")
        require(
            "tracked before" in git_diff.get("stdout", "")
            and "tracked after" in git_diff.get("stdout", ""),
            "git_diff omitted the exact tracked change",
        )
        git_add = call_tool("git_add", {"cwd": str(workspace), "path": "tracked.txt"})
        require(git_add.get("exit_code") == 0, "git_add failed")
        git_commit = call_tool(
            "git_commit",
            {"cwd": str(workspace), "message": "Validate compatibility fixture"},
        )
        require(git_commit.get("exit_code") == 0, "git_commit failed")
        final_head = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=workspace,
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout.strip()
        require(final_head != initial_head and len(final_head) == 40, "git_commit did not advance HEAD")
        git_log = call_tool("git_log", {"cwd": str(workspace), "limit": 2})
        require(git_log.get("exit_code") == 0, "git_log failed")
        require("Validate compatibility fixture" in git_log.get("stdout", ""), "git_log omitted the tool commit")

        shell = call_tool(
            "shell_exec",
            {"cwd": str(workspace), "command": "printf 'runtime-ok\\n'", "timeout_sec": 10},
        )
        require(shell.get("exit_code") == 0 and shell.get("timed_out") is False, "shell_exec did not complete")
        require(shell.get("stdout") == "runtime-ok\n", "shell_exec stdout changed")

        memory_key = "compatibility/legacy"
        memory_body = "legacy matrix needle"
        stored = call_tool(
            "memory_set",
            {"key": memory_key, "body": memory_body, "tags": ["p10-fixture"]},
        )
        stored_note = stored.get("note")
        require(stored.get("stored") is True, "memory_set did not report persistence")
        require(isinstance(stored_note, dict) and stored_note.get("body") == memory_body, "memory_set body changed")
        loaded = call_tool("memory_get", {"key": memory_key})
        require(loaded.get("found") is True and loaded.get("body") == memory_body, "memory_get lost the note")
        memory_list = call_tool(
            "memory_list",
            {"prefix": "compatibility/", "include_body": True, "limit": 10},
        )
        listed_notes = memory_list.get("notes")
        require(
            isinstance(listed_notes, list)
            and any(note.get("key") == memory_key and note.get("body") == memory_body for note in listed_notes),
            "memory_list omitted the fixture note",
        )
        memory_search = call_tool(
            "memory_search",
            {"query": memory_body, "include_body": True, "limit": 10},
        )
        searched_notes = memory_search.get("notes")
        require(
            isinstance(searched_notes, list)
            and any(note.get("key") == memory_key and note.get("body") == memory_body for note in searched_notes),
            "memory_search omitted the fixture note",
        )
        removed = call_tool("memory_delete", {"key": memory_key})
        require(removed.get("existed") is True and removed.get("deleted") is True, "memory_delete did not delete the note")

        checkpoint = call_tool(
            "session_checkpoint",
            {
                "goal": "Exercise preserved tool behavior",
                "status": "checking",
                "project_slug": "fixture",
                "cwd": str(workspace),
                "narrative": "Protocol fixture progress.",
                "next_actions": ["finish matrix"],
                "blockers": [],
                "key_files": [str(tracked)],
                "decisions": ["Use isolated files."],
                "chat_label": "P10 fixture",
            },
        )
        handoff_id = checkpoint.get("handoff_id")
        require(isinstance(handoff_id, str) and handoff_id, "session_checkpoint returned no handoff id")
        require(checkpoint.get("action") == "checkpoint", "session_checkpoint action changed")
        require(checkpoint.get("projection_ok") is True, "session_checkpoint projection did not commit")
        handoff = call_tool(
            "session_handoff",
            {
                "handoff_id": handoff_id,
                "status": "ready",
                "narrative": "Protocol fixture completed.",
                "next_actions": ["verify evidence"],
            },
        )
        require(handoff.get("handoff_id") == handoff_id, "session_handoff changed the handoff id")
        require(handoff.get("action") == "handoff", "session_handoff action changed")
        require(handoff.get("resume_ready") is True and handoff.get("handoff_required") is True, "handoff is not resumable")
        handoff_paths = handoff.get("paths")
        require(isinstance(handoff_paths, dict), "session_handoff returned no projection paths")
        handoff_json = pathlib.Path(str(handoff_paths.get("json", "")))
        require(handoff_json.is_file() and handoff_json.is_relative_to(home), "session_handoff JSON projection is missing")
        context_get = call_tool("context_get", {"handoff_id": handoff_id, "resume_ready": True})
        require(context_get.get("found") is True and context_get.get("handoff_id") == handoff_id, "context_get lost the handoff")
        context_list = call_tool("context_list", {"limit": 5})
        handoffs = context_list.get("handoffs")
        require(
            isinstance(handoffs, list)
            and any(item.get("id") == handoff_id and item.get("resume_ready") is True for item in handoffs),
            "context_list omitted the resumable handoff",
        )
        completed = call_tool(
            "agent_run_complete",
            {"session_id": session_id, "report": {"result": "passed"}},
        )
        require(completed.get("schema_complete") is True, "agent_run_complete rejected the fixture report")
        completed_session = completed.get("session")
        require(
            isinstance(completed_session, dict)
            and completed_session.get("id") == session_id
            and completed_session.get("status") == "closed",
            "agent_run_complete did not close the fixture session",
        )

        require(len(called_tools) == len(set(called_tools)), "legacy matrix called a tool more than once")
        require(set(called_tools) == set(legacy_tools), "legacy matrix did not call every preserved tool")
        stderr, return_code = process.close(shutdown_timeout)
        require(return_code == 0, f"legacy tool matrix server exited {return_code}")
    except BaseException:
        stop_failed_process(process, shutdown_timeout)
        raise

    return seal_probe({
        "name": name,
        "status": "passed",
        "checks": [
            "legacy_tool_success_all_baseline_methods",
            "text_and_structured_content_match_all_baseline_methods",
            "isolated_project_context",
            "filesystem_side_effects_verified",
            "git_side_effects_verified",
            "runtime_side_effects_verified",
            "memory_side_effects_verified",
            "continuity_side_effects_verified",
            "bounded_eof_shutdown",
        ],
        "wire_input": ndjson_artifact(requests),
        "requests": requests,
        "responses": responses,
        "called_tools": called_tools,
        "called_tools_sha256": normalized_hash(called_tools),
        "fixture": {
            "playbook_sha256": sha256_file(playbook),
            "initial_git_revision": initial_head,
            "final_git_revision": final_head,
            "converted_pdf_sha256": sha256_file(converted_pdf),
            "direct_pdf_sha256": sha256_file(direct_pdf),
            "handoff_projection_sha256": sha256_file(handoff_json),
        },
        "exit_codes": [return_code],
        "stderr": [stream_artifact(stderr)],
    })


def start_fixture_session(
    process: MCPProcess,
    requests: list[dict[str, Any]],
    responses: list[dict[str, Any]],
    workspace: pathlib.Path,
    response_timeout: float,
) -> str:
    request = {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/call",
        "params": {
            "name": "agent_run_start",
            "arguments": {
                "agent_id": "compatibility-fixture",
                "goal": "Exercise concurrent protocol behavior",
                "cwd": str(workspace),
            },
        },
    }
    requests.append(request)
    process.send(request)
    response = process.receive(2, "agent_run_start", response_timeout)
    structured = validate_tool_call_envelope(
        response,
        expected_error=False,
        expected_id=2,
    )
    responses.append(response)
    session_id = structured.get("session_id")
    require(isinstance(session_id, str) and session_id, "fixture session returned no session id")
    project_context = structured.get("project_context")
    require(isinstance(project_context, dict), "fixture session returned no project context")
    roots = project_context.get("authorization_roots")
    require(
        isinstance(roots, list)
        and any(
            isinstance(root, str)
            and pathlib.Path(root).exists()
            and os.path.samefile(root, workspace)
            for root in roots
        ),
        "fixture project root was not bound",
    )
    return session_id


def exercise_concurrent_mixed_correlation_probe(
    binary: pathlib.Path,
    root: pathlib.Path,
    response_timeout: float,
    shutdown_timeout: float,
) -> dict[str, Any]:
    name = "concurrent_mixed_request_correlation"
    home = root / name
    home.mkdir(parents=True, exist_ok=False)
    workspace, _, _ = prepare_tool_fixture(home, ["shell_exec"])
    process, requests, responses = initialize_process(binary, home, name, response_timeout)
    try:
        start_fixture_session(process, requests, responses, workspace, response_timeout)
        arrival_start = len(process.response_arrival_ids)
        slow_request = {
            "jsonrpc": "2.0",
            "id": 7,
            "method": "tools/call",
            "params": {
                "name": "shell_exec",
                "arguments": {
                    "cwd": str(workspace),
                    "command": "sleep 1; printf 'slow\\n'",
                    "timeout_sec": 10,
                },
            },
        }
        fast_request = {
            "jsonrpc": "2.0",
            "id": "7",
            "method": "ping",
            "params": {},
        }
        requests.extend([slow_request, fast_request])
        process.send(slow_request)
        process.send(fast_request)

        fast_response = process.receive("7", "concurrent string-id ping", response_timeout)
        validate_endpoint_response(fast_response, "ping", "7")
        responses.append(fast_response)
        slow_response = process.receive(7, "concurrent numeric-id shell_exec", response_timeout)
        slow_result = validate_tool_call_envelope(
            slow_response,
            expected_error=False,
            expected_id=7,
        )
        responses.append(slow_response)
        require(
            slow_result.get("exit_code") == 0
            and slow_result.get("timed_out") is False
            and slow_result.get("stdout") == "slow\n",
            "concurrent slow request did not complete successfully",
        )
        arrival_order = process.response_arrival_ids[arrival_start:]
        require(
            arrival_order == ["7", 7],
            f"concurrent responses did not complete out of order: {arrival_order!r}",
        )
        stderr, return_code = process.close(shutdown_timeout)
        require(return_code == 0, f"concurrent correlation server exited {return_code}")
    except BaseException:
        stop_failed_process(process, shutdown_timeout)
        raise
    return seal_probe({
        "name": name,
        "status": "passed",
        "checks": [
            "concurrent_mixed_request_correlation",
            "out_of_order_completion",
            "typed_numeric_and_string_request_ids",
            "buffered_response_retrieval",
            "exactly_one_response_per_request",
            "bounded_eof_shutdown",
        ],
        "wire_input": ndjson_artifact(requests),
        "requests": requests,
        "responses": responses,
        "response_arrival_ids": arrival_order,
        "exit_codes": [return_code],
        "stderr": [stream_artifact(stderr)],
    })


def fixture_process_is_running(process_identifier: int) -> bool:
    try:
        os.kill(process_identifier, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def wait_for_fixture_process_exit(process_identifier: int, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not fixture_process_is_running(process_identifier):
            return True
        time.sleep(0.02)
    return not fixture_process_is_running(process_identifier)


def terminate_fixture_sleep_if_needed(process_identifier: int | None) -> None:
    if process_identifier is None or not fixture_process_is_running(process_identifier):
        return
    inspected = subprocess.run(
        ["/bin/ps", "-p", str(process_identifier), "-o", "command="],
        capture_output=True,
        text=True,
        timeout=5,
    )
    command = inspected.stdout.strip()
    if inspected.returncode == 0 and command in {"sleep 10", "/bin/sleep 10"}:
        try:
            os.kill(process_identifier, signal.SIGKILL)
        except ProcessLookupError:
            pass
        wait_for_fixture_process_exit(process_identifier, 2.0)


def exercise_active_cancellation_probe(
    binary: pathlib.Path,
    root: pathlib.Path,
    response_timeout: float,
    shutdown_timeout: float,
) -> dict[str, Any]:
    name = "active_in_flight_cancellation"
    home = root / name
    home.mkdir(parents=True, exist_ok=False)
    workspace, _, _ = prepare_tool_fixture(home, ["shell_exec"])
    ready = workspace / "cancel-ready"
    child_path = workspace / "cancel-child.pid"
    process, requests, responses = initialize_process(binary, home, name, response_timeout)
    child_pid: int | None = None
    try:
        start_fixture_session(process, requests, responses, workspace, response_timeout)
        command = (
            "/bin/sleep 10 & child=$!; "
            f"printf '%s\\n' \"$child\" > {shlex.quote(str(child_path.resolve()))}; "
            f": > {shlex.quote(str(ready.resolve()))}; "
            "wait \"$child\""
        )
        target = {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": "shell_exec",
                "arguments": {
                    "cwd": str(workspace),
                    "command": command,
                    "timeout_sec": 20,
                },
            },
        }
        requests.append(target)
        process.send(target)
        ready_deadline = time.monotonic() + response_timeout
        while time.monotonic() < ready_deadline and not (ready.is_file() and child_path.is_file()):
            require(process.process.poll() is None, process.failure("server exited before cancellation became active"))
            time.sleep(0.02)
        require(ready.is_file() and child_path.is_file(), "active cancellation fixture did not reach its ready marker")
        child_text = child_path.read_text(encoding="utf-8").strip()
        require(child_text.isascii() and child_text.isdigit(), "active cancellation child pid is malformed")
        child_pid = int(child_text)
        require(child_pid > 1 and fixture_process_is_running(child_pid), "active cancellation child is not running")

        cancellation = {
            "jsonrpc": "2.0",
            "method": "notifications/cancelled",
            "params": {"requestId": 3, "reason": "p10-active-cancellation"},
        }
        requests.append(cancellation)
        cancellation_started = time.monotonic()
        process.send(cancellation)
        response = process.receive(3, "active cancelled shell_exec", response_timeout)
        cancellation_milliseconds = int((time.monotonic() - cancellation_started) * 1000)
        validate_rpc_error(response, 3, -32800)
        responses.append(response)
        require(
            cancellation_milliseconds <= int(response_timeout * 1000),
            "active cancellation response exceeded its bounded deadline",
        )
        require(
            wait_for_fixture_process_exit(child_pid, min(5.0, response_timeout)),
            "active cancellation did not terminate the child process",
        )
        stderr, return_code = process.close(shutdown_timeout)
        require(return_code == 0, f"active cancellation server exited {return_code}")
    except BaseException:
        stop_failed_process(process, max(15.0, shutdown_timeout))
        terminate_fixture_sleep_if_needed(child_pid)
        raise
    return seal_probe({
        "name": name,
        "status": "passed",
        "checks": [
            "active_in_flight_cancellation",
            "cancelled_error_code",
            "cancelled_work_terminated",
            "late_success_suppressed",
            "exactly_one_response_per_request",
            "bounded_eof_shutdown",
        ],
        "wire_input": ndjson_artifact(requests),
        "requests": requests,
        "responses": responses,
        "cancellation_milliseconds": cancellation_milliseconds,
        "child_process_terminated": True,
        "exit_codes": [return_code],
        "stderr": [stream_artifact(stderr)],
    })


def exercise_active_eof_shutdown_probe(
    binary: pathlib.Path,
    root: pathlib.Path,
    response_timeout: float,
    shutdown_timeout: float,
) -> dict[str, Any]:
    name = "active_request_eof_shutdown"
    home = root / name
    home.mkdir(parents=True, exist_ok=False)
    workspace, _, _ = prepare_tool_fixture(home, ["shell_exec"])
    ready = workspace / "eof-ready"
    child_path = workspace / "eof-child.pid"
    process, requests, responses = initialize_process(binary, home, name, response_timeout)
    child_pid: int | None = None
    process_finished = False
    try:
        start_fixture_session(process, requests, responses, workspace, response_timeout)
        command = (
            "/bin/sleep 10 & child=$!; "
            f"printf '%s\\n' \"$child\" > {shlex.quote(str(child_path.resolve()))}; "
            f": > {shlex.quote(str(ready.resolve()))}; "
            "wait \"$child\""
        )
        target = {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": "shell_exec",
                "arguments": {
                    "cwd": str(workspace),
                    "command": command,
                    "timeout_sec": 20,
                },
            },
        }
        requests.append(target)
        process.send(target)
        ready_deadline = time.monotonic() + response_timeout
        while time.monotonic() < ready_deadline and not (ready.is_file() and child_path.is_file()):
            require(process.process.poll() is None, process.failure("server exited before EOF fixture became active"))
            time.sleep(0.02)
        require(ready.is_file() and child_path.is_file(), "active EOF fixture did not reach its ready marker")
        child_text = child_path.read_text(encoding="utf-8").strip()
        require(child_text.isascii() and child_text.isdigit(), "active EOF child pid is malformed")
        child_pid = int(child_text)
        require(child_pid > 1 and fixture_process_is_running(child_pid), "active EOF child is not running")

        eof_started = time.monotonic()
        trailing, stderr, return_code = process.finish(shutdown_timeout)
        process_finished = True
        eof_shutdown_milliseconds = int((time.monotonic() - eof_started) * 1000)
        require(return_code == 0, f"active EOF server exited {return_code}")
        require(
            eof_shutdown_milliseconds <= int(shutdown_timeout * 1000),
            "active EOF shutdown exceeded its bounded deadline",
        )
        require(
            not trailing.strip(),
            f"active EOF shutdown emitted an unexpected late response: {trailing[:500]!r}",
        )
        require(
            wait_for_fixture_process_exit(child_pid, min(5.0, response_timeout)),
            "active EOF shutdown did not terminate the child process",
        )
    except BaseException:
        if not process_finished:
            stop_failed_process(process, max(15.0, shutdown_timeout))
        terminate_fixture_sleep_if_needed(child_pid)
        raise
    return seal_probe({
        "name": name,
        "status": "passed",
        "checks": [
            "active_request_eof_shutdown",
            "cli_serve_disconnect_shutdown",
            "runtime_child_terminated_on_disconnect",
            "no_late_response_after_eof",
            "zero_exit_after_eof",
            "bounded_eof_shutdown",
        ],
        "wire_input": ndjson_artifact(requests),
        "requests": requests,
        "responses": responses,
        "eof_shutdown_milliseconds": eof_shutdown_milliseconds,
        "child_process_terminated": True,
        "trailing_stdout": stream_artifact(trailing),
        "exit_codes": [return_code],
        "stderr": [stream_artifact(stderr)],
    })


def exercise_content_length_probe(
    binary: pathlib.Path,
    root: pathlib.Path,
    response_timeout: float,
    shutdown_timeout: float,
) -> dict[str, Any]:
    name = "content_length_input"
    home = root / name
    home.mkdir(parents=True, exist_ok=False)
    request = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {"protocolVersion": SUPPORTED_PROTOCOL_VERSIONS[0], "capabilities": {}},
    }
    body = canonical_bytes(request)
    frame = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body
    process = MCPProcess(binary, home, name)
    try:
        process.send_raw(frame.decode("utf-8"))
        response = process.receive(1, "Content-Length initialize", response_timeout)
        validate_endpoint_response(response, "initialize", 1)
        require(
            response["result"]["protocolVersion"] == SUPPORTED_PROTOCOL_VERSIONS[0],
            "Content-Length initialize negotiated the wrong protocol",
        )
        stderr, return_code = process.close(shutdown_timeout)
        require(return_code == 0, f"Content-Length server exited {return_code}")
    except BaseException:
        process.abort()
        raise
    return seal_probe({
        "name": name,
        "status": "passed",
        "checks": ["valid_content_length_input", "ndjson_response", "bounded_eof_shutdown"],
        "wire_input": {
            "framing": "content_length",
            "bytes": len(frame),
            "sha256": sha256_bytes(frame),
            "declared_content_length": len(body),
        },
        "requests": [request],
        "responses": [response],
        "exit_codes": [return_code],
        "stderr": [stream_artifact(stderr)],
    })


def exercise_rejected_framing_probe(
    binary: pathlib.Path,
    root: pathlib.Path,
    *,
    name: str,
    payload: bytes,
    diagnostic_markers: tuple[str, ...],
    checks: list[str],
    shutdown_timeout: float,
) -> dict[str, Any]:
    home = root / name
    home.mkdir(parents=True, exist_ok=False)
    process = MCPProcess(binary, home, name)
    try:
        process.send_raw(payload.decode("utf-8"))
        trailing, stderr, return_code = process.finish(shutdown_timeout)
    except BaseException:
        process.abort()
        raise
    diagnostic = stderr.decode("utf-8", errors="replace")
    require(return_code != 0, f"{name} malformed frame was accepted")
    require(not trailing.strip(), f"{name} emitted a protocol response before rejection")
    require(stderr, f"{name} rejection emitted no diagnostic")
    require(
        all(marker.casefold() in diagnostic.casefold() for marker in diagnostic_markers),
        f"{name} diagnostic does not prove the expected rejection: {diagnostic[-1000:]}",
    )
    return seal_probe({
        "name": name,
        "status": "passed",
        "checks": checks,
        "wire_input": {
            "framing": "content_length",
            "bytes": len(payload),
            "sha256": sha256_bytes(payload),
        },
        "requests": [],
        "responses": [],
        "exit_codes": [return_code],
        "stdout": [stream_artifact(trailing)],
        "stderr": [stream_artifact(stderr, include_tail=True)],
    })


def exercise_restart_eof_probe(
    binary: pathlib.Path,
    root: pathlib.Path,
    response_timeout: float,
    shutdown_timeout: float,
) -> dict[str, Any]:
    name = "restart_and_eof"
    home = root / name
    home.mkdir(parents=True, exist_ok=False)
    cycles: list[dict[str, Any]] = []
    process_ids: list[int] = []
    for ordinal in (1, 2):
        process, requests, responses = initialize_process(
            binary,
            home,
            f"{name}-{ordinal}",
            response_timeout,
        )
        process_ids.append(process.process.pid)
        ping = {"jsonrpc": "2.0", "id": 2, "method": "ping", "params": {}}
        try:
            requests.append(ping)
            process.send(ping)
            response = process.receive(2, "ping", response_timeout)
            validate_endpoint_response(response, "ping", 2)
            responses.append(response)
            stderr, return_code = process.close(shutdown_timeout)
            require(return_code == 0, f"restart cycle {ordinal} exited {return_code}")
        except BaseException:
            process.abort()
            raise
        if ordinal == 1:
            require((home / "store.sqlite").is_file(), "first EOF cycle did not persist the store for restart")
        cycles.append({
            "ordinal": ordinal,
            "wire_input": ndjson_artifact(requests),
            "requests": requests,
            "responses": responses,
            "exit_code": return_code,
            "stderr": stream_artifact(stderr),
        })
    require(process_ids[0] != process_ids[1], "restart probe did not use a fresh process")
    return seal_probe({
        "name": name,
        "status": "passed",
        "checks": ["bounded_eof_shutdown", "durable_home_reopen", "fresh_process_restart", "post_restart_ping"],
        "cycles": cycles,
        "fresh_processes": True,
        "exit_codes": [cycle["exit_code"] for cycle in cycles],
        "stderr": [cycle["stderr"] for cycle in cycles],
    })


def exercise_pagination_probe(
    binary: pathlib.Path,
    root: pathlib.Path,
    response_timeout: float,
    shutdown_timeout: float,
) -> dict[str, Any]:
    name = "pagination"
    home = root / name
    home.mkdir(parents=True, exist_ok=False)
    project_path = home / "fixture-project"
    project_path.mkdir()
    process, requests, responses = initialize_process(binary, home, name, response_timeout)

    def call_tool(request_id: int, tool_name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        request = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "tools/call",
            "params": {"name": tool_name, "arguments": arguments},
        }
        requests.append(request)
        process.send(request)
        response = process.receive(request_id, tool_name, response_timeout)
        structured = validate_tool_call_envelope(
            response,
            expected_error=False,
            expected_id=request_id,
        )
        responses.append(response)
        return structured

    try:
        initialized = call_tool(2, "project_memory.initialize", {"project_path": str(project_path)})
        project_id = initialized.get("project_id")
        require(isinstance(project_id, str), "project-memory initialization returned no project id")
        try:
            uuid.UUID(project_id)
        except (ValueError, AttributeError) as error:
            raise CompatibilityError("project-memory initialization returned an invalid project id") from error

        inserted_ids: list[str] = []
        for ordinal in range(3):
            remembered = call_tool(
                3 + ordinal,
                "project_memory.remember",
                {
                    "project_id": project_id,
                    "kind": "fact",
                    "title": f"Pagination fixture {ordinal}",
                    "summary": f"Bounded pagination record {ordinal}",
                    "idempotency_key": f"p10-pagination-{ordinal}",
                },
            )
            require(remembered.get("disposition") == "inserted", "pagination fixture was not inserted")
            record_id = remembered.get("record_id")
            require(isinstance(record_id, str) and record_id, "pagination fixture returned no record id")
            inserted_ids.append(record_id)
        require(len(set(inserted_ids)) == 3, "pagination fixture record ids are not unique")

        first_page = call_tool(
            6,
            "project_memory.list_recent",
            {"project_id": project_id, "limit": 2, "maximum_response_bytes": 4096},
        )
        first_records = first_page.get("records")
        require(isinstance(first_records, list) and len(first_records) == 2, "first page did not contain two records")
        require(first_page.get("count") == 2, "first page count changed")
        require(first_page.get("truncated") is True, "first page was not marked truncated")
        cursor = first_page.get("next_cursor")
        require(isinstance(cursor, str) and cursor, "first page returned no cursor")

        second_page = call_tool(
            7,
            "project_memory.list_recent",
            {"project_id": project_id, "limit": 2, "cursor": cursor, "maximum_response_bytes": 4096},
        )
        second_records = second_page.get("records")
        require(isinstance(second_records, list) and len(second_records) == 1, "second page did not contain one record")
        require(second_page.get("count") == 1, "second page count changed")
        require(second_page.get("truncated") is False, "second page remained truncated")
        require(second_page.get("next_cursor") is None, "second page returned a terminal cursor")

        first_ids = [record.get("id") for record in first_records if isinstance(record, dict)]
        second_ids = [record.get("id") for record in second_records if isinstance(record, dict)]
        require(len(first_ids) == 2 and len(second_ids) == 1, "paged records are malformed")
        require(not set(first_ids) & set(second_ids), "pagination repeated a record across pages")
        require(set(first_ids + second_ids) == set(inserted_ids), "pagination skipped or invented records")

        stderr, return_code = process.close(shutdown_timeout)
        require(return_code == 0, f"pagination server exited {return_code}")
    except BaseException:
        process.abort()
        raise

    return seal_probe({
        "name": name,
        "status": "passed",
        "checks": [
            "project_memory_fixture_seeded",
            "opaque_cursor_returned",
            "cursor_page_has_no_duplicates",
            "cursor_page_has_no_omissions",
            "terminal_page_has_no_cursor",
            "bounded_eof_shutdown",
        ],
        "wire_input": ndjson_artifact(requests),
        "requests": requests,
        "responses": responses,
        "inserted_record_ids_sha256": normalized_hash(sorted(inserted_ids)),
        "exit_codes": [return_code],
        "stderr": [stream_artifact(stderr)],
    })


def exercise_protocol(
    binary: pathlib.Path,
    request_fixture: list[dict[str, Any]],
    protocol_version: str,
    root: pathlib.Path,
    response_timeout: float,
    shutdown_timeout: float,
) -> dict[str, Any]:
    home = root / protocol_version
    home.mkdir(parents=True, exist_ok=False)
    process = MCPProcess(binary, home, protocol_version)
    requests: list[dict[str, Any]] = []
    responses: list[dict[str, Any]] = []
    try:
        for template in request_fixture:
            request = copy.deepcopy(template)
            if request["method"] == "initialize":
                request["params"]["protocolVersion"] = protocol_version
            requests.append(request)
            process.send(request)
            if "id" not in request:
                continue
            response = process.receive(request["id"], request["method"], response_timeout)
            validate_endpoint_response(response, request["method"], request["id"])
            if request["method"] == "initialize":
                negotiated = response["result"]["protocolVersion"]
                require(
                    negotiated == protocol_version,
                    f"protocol {protocol_version} negotiated as {negotiated!r}",
                )
            responses.append(response)
        stderr, return_code = process.close(shutdown_timeout)
        require(return_code == 0, f"MCP server exited {return_code} for protocol {protocol_version}")
    except BaseException:
        process.abort()
        raise
    mapped = response_map(responses, f"protocol {protocol_version}")
    tools = tool_map(mapped[2], f"protocol {protocol_version}")
    return {
        "protocol_version": protocol_version,
        "requests": requests,
        "responses": responses,
        "stderr": {
            "bytes": len(stderr),
            "sha256": sha256_bytes(stderr),
        },
        "exit_code": return_code,
        "tool_count": len(tools),
        "tool_descriptors_sha256": normalized_hash([tools[name] for name in sorted(tools)]),
        "resources_sha256": normalized_hash(mapped[3]["result"]["resources"]),
        "prompts_sha256": normalized_hash(mapped[4]["result"]["prompts"]),
        "normalized_transcript_sha256": normalized_hash({"requests": requests, "responses": responses}),
    }


def git_source_state(root: pathlib.Path) -> dict[str, Any]:
    revision = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    require(len(revision) == 40 and all(character in "0123456789abcdef" for character in revision), "invalid Git revision")
    status_output = subprocess.run(
        ["git", "status", "--porcelain=v1", "--untracked-files=all"],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    status = status_output.splitlines()
    return {
        "repository_root": str(root),
        "revision": revision,
        "dirty": bool(status),
        "status": status,
        "status_sha256": sha256_bytes(status_output.encode("utf-8")),
    }


def atomic_write(path: pathlib.Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = pathlib.Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def output_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, allow_nan=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def ensure_distinct_paths(paths: list[tuple[str, pathlib.Path | None]]) -> None:
    present = [(label, path.resolve()) for label, path in paths if path is not None]
    for index, (left_label, left) in enumerate(present):
        for right_label, right in present[index + 1:]:
            require(left != right, f"{left_label} and {right_label} resolve to the same path: {left}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=pathlib.Path)
    parser.add_argument("--baseline-transcript", type=pathlib.Path, default=DEFAULT_BASELINE_TRANSCRIPT)
    parser.add_argument("--requests", type=pathlib.Path, default=DEFAULT_REQUESTS)
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--transcript-output", type=pathlib.Path)
    parser.add_argument("--response-timeout", type=float, default=10.0)
    parser.add_argument("--shutdown-timeout", type=float, default=5.0)
    parser.add_argument("--require-clean", action="store_true")
    args = parser.parse_args()

    binary = args.binary.resolve()
    baseline_path = args.baseline_transcript.resolve()
    requests_path = args.requests.resolve()
    output_path = args.output.resolve() if args.output else None
    transcript_path = args.transcript_output.resolve() if args.transcript_output else None
    ensure_distinct_paths([
        ("binary", binary),
        ("baseline transcript", baseline_path),
        ("request fixture", requests_path),
        ("report output", output_path),
        ("transcript output", transcript_path),
    ])
    require(binary.is_file() and os.access(binary, os.X_OK), f"binary is not executable: {binary}")
    require(math.isfinite(args.response_timeout) and args.response_timeout > 0, "response timeout must be finite and positive")
    require(math.isfinite(args.shutdown_timeout) and args.shutdown_timeout > 0, "shutdown timeout must be finite and positive")

    input_artifacts = {
        "binary": artifact(binary),
        "baseline_transcript": artifact(baseline_path),
        "request_fixture": artifact(requests_path),
    }
    require(
        input_artifacts["baseline_transcript"]["sha256"] == EXPECTED_BASELINE_TRANSCRIPT_SHA256,
        "baseline transcript does not match the preserved P01 artifact",
    )
    require(
        input_artifacts["request_fixture"]["sha256"] == EXPECTED_REQUEST_FIXTURE_SHA256,
        "request fixture does not match the preserved P01 artifact",
    )

    request_fixture = load_ndjson(requests_path, "request fixture")
    baseline_responses = load_ndjson(baseline_path, "baseline transcript")
    validate_request_fixture(request_fixture)
    baseline_by_id = response_map(baseline_responses, "baseline transcript")
    for request in request_fixture:
        if "id" in request:
            validate_endpoint_response(baseline_by_id[request["id"]], request["method"], request["id"])
    require(
        baseline_by_id[1]["result"]["protocolVersion"] == request_fixture[0]["params"]["protocolVersion"],
        "baseline initialize protocol negotiation is inconsistent",
    )
    baseline_tools = tool_map(baseline_by_id[2], "baseline transcript")
    require(
        len(baseline_tools) == EXPECTED_LEGACY_TOOL_COUNT,
        f"expected {EXPECTED_LEGACY_TOOL_COUNT} baseline tools, found {len(baseline_tools)}",
    )
    require(isinstance(baseline_by_id[3]["result"].get("resources"), list), "baseline resources are malformed")
    require(isinstance(baseline_by_id[4]["result"].get("prompts"), list), "baseline prompts are malformed")
    require(baseline_by_id[5]["result"] == {}, "baseline ping result is malformed")

    source = git_source_state(REPOSITORY_ROOT)
    manifest_before = source_manifest(REPOSITORY_ROOT)
    if args.require_clean:
        require(not source["dirty"], "repository is dirty but --require-clean was requested")

    with tempfile.TemporaryDirectory(prefix="forge-p10-protocol-") as temporary_root:
        runtime_root = pathlib.Path(temporary_root)
        runs = [
            exercise_protocol(
                binary,
                request_fixture,
                version,
                runtime_root,
                args.response_timeout,
                args.shutdown_timeout,
            )
            for version in SUPPORTED_PROTOCOL_VERSIONS
        ]
        wire_root = runtime_root / "wire-probes"
        wire_root.mkdir()
        content_length_probe = exercise_content_length_probe(
            binary,
            wire_root,
            args.response_timeout,
            args.shutdown_timeout,
        )
        malformed_framing_probe = exercise_rejected_framing_probe(
            binary,
            wire_root,
            name="malformed_content_length",
            payload=b"Content-Length: not-a-number\r\n\r\n{}",
            diagnostic_markers=("json",),
            checks=["malformed_content_length_rejected", "no_response_before_rejection", "bounded_failure_exit"],
            shutdown_timeout=args.shutdown_timeout,
        )
        oversized_framing_probe = exercise_rejected_framing_probe(
            binary,
            wire_root,
            name="oversized_content_length",
            payload=f"Content-Length: {MAXIMUM_MCP_MESSAGE_BYTES + 1}\r\n\r\n".encode("ascii"),
            diagnostic_markers=("messageTooLarge", str(MAXIMUM_MCP_MESSAGE_BYTES)),
            checks=["oversized_content_length_rejected", "no_body_read", "bounded_failure_exit"],
            shutdown_timeout=args.shutdown_timeout,
        )
        unknown_method_probe = exercise_initialized_probe(
            binary,
            wire_root,
            "unknown_method",
            {"jsonrpc": "2.0", "id": 2, "method": "forge.__p10_unsupported_method__", "params": {}},
            lambda response: validate_rpc_error(response, 2, -32601),
            ["unknown_method_error_code", "unknown_method_error_envelope", "bounded_eof_shutdown"],
            args.response_timeout,
            args.shutdown_timeout,
        )
        legacy_success_probe = exercise_legacy_tool_success_matrix(
            binary,
            wire_root,
            sorted(baseline_tools),
            args.response_timeout,
            args.shutdown_timeout,
        )
        typed_error_probe = exercise_initialized_probe(
            binary,
            wire_root,
            "typed_tool_error",
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": {"name": "memory_get", "arguments": {}},
            },
            validate_typed_error_response,
            ["typed_tool_error", "invalid_key_code", "text_and_structured_content_match", "is_error_true"],
            args.response_timeout,
            args.shutdown_timeout,
        )
        cancellation_probe = exercise_initialized_probe(
            binary,
            wire_root,
            "cancellation",
            {"jsonrpc": "2.0", "id": 2, "method": "ping", "params": {}},
            lambda response: validate_rpc_error(response, 2, -32800),
            ["cancellation_notification", "cancelled_error_code", "bounded_eof_shutdown"],
            args.response_timeout,
            args.shutdown_timeout,
            before_target=[{
                "jsonrpc": "2.0",
                "method": "notifications/cancelled",
                "params": {"requestId": 2, "reason": "p10-wire-probe"},
            }],
        )
        concurrent_probe = exercise_concurrent_mixed_correlation_probe(
            binary,
            wire_root,
            args.response_timeout,
            args.shutdown_timeout,
        )
        active_cancellation_probe = exercise_active_cancellation_probe(
            binary,
            wire_root,
            args.response_timeout,
            args.shutdown_timeout,
        )
        active_eof_shutdown_probe = exercise_active_eof_shutdown_probe(
            binary,
            wire_root,
            args.response_timeout,
            args.shutdown_timeout,
        )
        restart_probe = exercise_restart_eof_probe(
            binary,
            wire_root,
            args.response_timeout,
            args.shutdown_timeout,
        )
        pagination_probe = exercise_pagination_probe(
            binary,
            wire_root,
            args.response_timeout,
            args.shutdown_timeout,
        )
        wire_probes = [
            content_length_probe,
            malformed_framing_probe,
            oversized_framing_probe,
            unknown_method_probe,
            legacy_success_probe,
            typed_error_probe,
            cancellation_probe,
            concurrent_probe,
            active_cancellation_probe,
            active_eof_shutdown_probe,
            restart_probe,
            pagination_probe,
        ]

    require(
        input_artifacts
        == {
            "binary": artifact(binary),
            "baseline_transcript": artifact(baseline_path),
            "request_fixture": artifact(requests_path),
        },
        "an executable or preserved baseline artifact changed during the check",
    )
    require(source == git_source_state(REPOSITORY_ROOT), "repository source state changed during the check")
    require(
        manifest_before == source_manifest(REPOSITORY_ROOT),
        "source/test/checker manifest changed during the check",
    )

    baseline_names = set(baseline_tools)
    reference_tools: dict[str, dict[str, Any]] | None = None
    schema_breaks: list[dict[str, Any]] = []
    description_breaks: list[dict[str, Any]] = []
    removed_tools: set[str] = set()
    version_tool_hashes: dict[str, str] = {}
    version_inventory_hashes: dict[str, str] = {}
    additive_names: set[str] | None = None
    for run in runs:
        mapped = response_map(run["responses"], f"protocol {run['protocol_version']}")
        current_tools = tool_map(mapped[2], f"protocol {run['protocol_version']}")
        current_names = set(current_tools)
        removed_tools.update(baseline_names - current_names)
        current_additive = current_names - baseline_names
        if additive_names is None:
            additive_names = current_additive
        else:
            require(
                additive_names == current_additive,
                f"additive tool inventory differs for protocol {run['protocol_version']}",
            )
        for name in sorted(baseline_names & current_names):
            old_descriptor = baseline_tools[name]
            new_descriptor = current_tools[name]
            if normalize_description(old_descriptor["description"]) != normalize_description(new_descriptor["description"]):
                description_breaks.append({"protocol_version": run["protocol_version"], "tool": name})
            for detail in compare_schema(
                old_descriptor["inputSchema"],
                new_descriptor["inputSchema"],
                f"tools.{name}.inputSchema",
            ):
                schema_breaks.append({
                    "protocol_version": run["protocol_version"],
                    "tool": name,
                    "detail": detail,
                })
        normalized_tools = [current_tools[name] for name in sorted(current_tools)]
        normalized_inventory = sorted(current_tools)
        version_tool_hashes[run["protocol_version"]] = normalized_hash(normalized_tools)
        version_inventory_hashes[run["protocol_version"]] = normalized_hash(normalized_inventory)
        if reference_tools is None:
            reference_tools = current_tools
        else:
            require(
                normalized_hash([reference_tools[name] for name in sorted(reference_tools)])
                == normalized_hash(normalized_tools),
                f"tool descriptors differ for protocol {run['protocol_version']}",
            )

    require(not removed_tools, f"legacy tools were removed: {sorted(removed_tools)}")
    require(not description_breaks, f"legacy tool descriptions changed: {description_breaks}")
    require(not schema_breaks, f"legacy tool schemas narrowed: {schema_breaks}")
    require(reference_tools is not None and additive_names is not None, "protocol runs produced no tool inventory")

    wire_coverage = {
        probe["name"]: {"status": "passed", "probe": probe["name"]}
        for probe in wire_probes
    }
    transcript_document = {
        "schema_version": 1,
        "protocol_versions": list(SUPPORTED_PROTOCOL_VERSIONS),
        "runs": runs,
        "wire_coverage": wire_coverage,
        "wire_probes": wire_probes,
    }
    transcript_data = output_bytes(transcript_document)
    transcript_artifact: dict[str, Any] | None = None
    if transcript_path:
        atomic_write(transcript_path, transcript_data)
        transcript_artifact = artifact(transcript_path)

    current_legacy_descriptors = [reference_tools[name] for name in sorted(baseline_names)]
    additive_descriptors = [reference_tools[name] for name in sorted(additive_names)]
    uncovered_checks: list[str] = []
    report: dict[str, Any] = {
        "schema_version": 1,
        "status": "passed",
        "ok": True,
        "scope": "executable descriptor, success, concurrency, cancellation, framing, restart, and pagination compatibility",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source": source,
        "source_manifest": manifest_before,
        "artifacts": {
            **input_artifacts,
            "runtime_transcript": transcript_artifact,
        },
        "protocol_versions": list(SUPPORTED_PROTOCOL_VERSIONS),
        "legacy_tool_count": len(baseline_tools),
        "current_tool_count": len(reference_tools),
        "additive_tool_count": len(additive_names),
        "legacy_tools": sorted(baseline_names),
        "additive_tools": sorted(additive_names),
        "removed_tools": [],
        "schema_breaks": [],
        "description_breaks": [],
        "compatibility_checks": [
            "p01_baseline_artifacts_valid",
            "initialize_all_supported_versions",
            "tools_list_all_supported_versions",
            "resources_list_all_supported_versions",
            "prompts_list_all_supported_versions",
            "ping_all_supported_versions",
            "legacy_tool_inventory_preserved",
            "legacy_descriptions_preserved",
            "legacy_schemas_recursively_non_narrowing",
            "protocol_tool_descriptors_identical",
            "additive_tools_inventoried",
            "bounded_process_shutdown",
            "valid_content_length_input",
            "malformed_content_length_rejected",
            "oversized_content_length_rejected",
            "unknown_method_negative_32601",
            "legacy_tool_success_all_baseline_methods",
            "legacy_tool_call_success_envelopes",
            "typed_tool_error_envelope",
            "pre_cancelled_request_negative_32800",
            "active_in_flight_cancellation",
            "active_request_eof_shutdown",
            "cli_serve_disconnect_shutdown",
            "concurrent_mixed_request_correlation",
            "typed_numeric_and_string_request_ids",
            "fresh_process_restart_and_eof",
            "project_memory_cursor_pagination",
        ],
        "wire_coverage": wire_coverage,
        "uncovered_checks": uncovered_checks,
        "normalized_hashes": {
            "request_fixture": normalized_hash(request_fixture),
            "baseline_transcript": normalized_hash(baseline_responses),
            "baseline_legacy_descriptors": normalized_hash(
                [baseline_tools[name] for name in sorted(baseline_tools)]
            ),
            "current_legacy_descriptors": normalized_hash(current_legacy_descriptors),
            "additive_descriptors": normalized_hash(additive_descriptors),
            "additive_inventory": normalized_hash(sorted(additive_names)),
            "runtime_transcript": normalized_hash(transcript_document),
            "tool_descriptors_by_protocol": version_tool_hashes,
            "tool_inventories_by_protocol": version_inventory_hashes,
            "wire_probes": normalized_hash(wire_probes),
            "wire_probes_by_name": {
                probe["name"]: probe["normalized_probe_payload_sha256"]
                for probe in wire_probes
            },
        },
        "protocol_runs": [
            {
                key: value
                for key, value in run.items()
                if key not in {"requests", "responses"}
            }
            for run in runs
        ],
        "wire_probe_results": [
            {
                "name": probe["name"],
                "status": probe["status"],
                "checks": probe["checks"],
                "exit_codes": probe["exit_codes"],
                "stderr": probe["stderr"],
                "wire_input": probe.get("wire_input"),
                "cycle_wire_inputs": [cycle["wire_input"] for cycle in probe.get("cycles", [])],
                "normalized_probe_payload_sha256": probe["normalized_probe_payload_sha256"],
            }
            for probe in wire_probes
        ],
    }
    report["normalized_hashes"]["report_payload_without_self_hash"] = normalized_hash(report)
    serialized = output_bytes(report)
    if output_path:
        atomic_write(output_path, serialized)
    sys.stdout.buffer.write(serialized)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (CompatibilityError, OSError, subprocess.SubprocessError) as error:
        print(f"protocol compatibility check failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
