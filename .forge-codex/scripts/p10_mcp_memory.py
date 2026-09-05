#!/usr/bin/env python3
"""Observe memory behavior through the ordinary embedded MCP CLI.

This is a supporting driver for record_command.py, not an acceptance ledger.
Its disposable config.json authorizes fixture roots; native onboarding, signing,
installation, migration and GUI behavior require their separate qualifications.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import pathlib
import selectors
import subprocess
import tempfile
import time
import uuid
from datetime import datetime, timezone
from typing import Any

from check_p10_protocol_compatibility import (
    CompatibilityError, MCPProcess, SUPPORTED_PROTOCOL_VERSIONS, atomic_write,
    canonical_bytes, configure_allowed_roots, git_source_state, normalized_hash,
    output_bytes, require, sha256_bytes, sha256_file, tool_map,
    validate_endpoint_response, validate_tool_call_envelope,
)
from evidence_support import source_manifest
from record_command import terminate_process_group


MAXIMUM_STREAM_BYTES = 1024 * 1024
MAXIMUM_REQUEST_BYTES = 16 * 1024
MAXIMUM_CALLS_PER_PROCESS = 80
MAXIMUM_MATRIX_SECONDS = 120
RESPONSE_SECONDS = 10
SHUTDOWN_SECONDS = 5
LEGACY_TOOLS = {"memory_set", "memory_get", "memory_list", "memory_delete", "memory_search"}
PROJECT_TOOLS = {
    "project_memory." + name for name in (
        "initialize", "remember", "remember_batch", "search", "get", "update",
        "forget", "list_recent", "link", "export", "import", "status",
    )
}


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def raw_artifact(value: bytes) -> dict[str, Any]:
    return {"bytes": len(value), "sha256": sha256_bytes(value),
            "base64": base64.b64encode(value).decode("ascii")}


class ObservedMCPProcess(MCPProcess):
    """Use the existing framing parser with bounded, retained duplex wire I/O.

    Only the observer transport differs: it drains both pipes without workers,
    limits total bytes/calls/time, and never inherits provider/host-test settings.
    """

    def __init__(self, binary: pathlib.Path, home: pathlib.Path,
                 label: str, deadline: float, observation: dict[str, Any]) -> None:
        self.deadline = deadline
        self.observation = observation
        self.environment = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home),
            "TMPDIR": str(home / "tmp"), "LANG": "en_US.UTF-8",
            "FORGE_CONDUCTOR_HOME": str(home), "FORGE_MCP_ROLE": "primary",
        }
        (home / "tmp").mkdir(exist_ok=True)
        self.requests: list[dict[str, Any]] = []
        self.responses: list[dict[str, Any]] = []
        self.raw_input = bytearray()
        self.raw_output = bytearray()
        self.raw_error = bytearray()
        self._stdout_buffer = bytearray()
        self._pending_responses: list[tuple[dict[str, Any], int]] = []
        self._pending_response_bytes = 0
        self._response_arrival_ids: list[Any] = []
        observation.update(label=label, argv=[str(binary), "serve"], cwd=str(home),
                           environment=self.environment, started_at=now(),
                           requests=self.requests, responses=self.responses,
                           maximum_stream_bytes=MAXIMUM_STREAM_BYTES,
                           maximum_calls=MAXIMUM_CALLS_PER_PROCESS,
                           response_timeout_seconds=RESPONSE_SECONDS,
                           shutdown_timeout_seconds=SHUTDOWN_SECONDS,
                           timed_out=False, stream_limit_exceeded=False)
        self.process = subprocess.Popen(
            observation["argv"], cwd=home, env=self.environment,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True, bufsize=0,
        )
        observation["pid"] = self.process.pid
        assert self.process.stdin and self.process.stdout and self.process.stderr
        self._stdout_descriptor = self.process.stdout.fileno()
        self.selector = selectors.DefaultSelector()
        for stream in (self.process.stdout, self.process.stderr):
            os.set_blocking(stream.fileno(), False)
            self.selector.register(stream, selectors.EVENT_READ)
        os.set_blocking(self.process.stdin.fileno(), False)

    def send_raw(self, value: str) -> None:
        data = value.encode("utf-8")
        require(len(data) <= MAXIMUM_REQUEST_BYTES, "request exceeds byte bound")
        require(len(self.raw_input) + len(data) <= MAXIMUM_STREAM_BYTES, "input exceeds byte bound")
        assert self.process.stdin
        end = min(self.deadline, time.monotonic() + RESPONSE_SECONDS)
        offset = 0
        while offset < len(data):
            self._check_deadline(end)
            try:
                count = os.write(self.process.stdin.fileno(), data[offset:])
                require(count > 0, "MCP stdin closed")
                self.raw_input.extend(data[offset:offset + count])
                offset += count
            except BlockingIOError:
                self._pump(end)

    def _check_deadline(self, end: float) -> None:
        if time.monotonic() >= end:
            self.observation["timed_out"] = True
            raise CompatibilityError("MCP input/response/shutdown deadline exceeded")

    def _pump(self, end: float) -> None:
        self._check_deadline(end)
        for key, _ in self.selector.select(min(0.05, max(0, end - time.monotonic()))):
            try:
                block = os.read(key.fd, 65536)
            except BlockingIOError:
                continue
            if not block:
                self.selector.unregister(key.fileobj)
                continue
            output = key.fd == self._stdout_descriptor
            target = self.raw_output if output else self.raw_error
            allowed = MAXIMUM_STREAM_BYTES - len(target)
            target.extend(block[:allowed])
            if len(block) > allowed:
                self.observation["stream_limit_exceeded"] = True
                raise CompatibilityError("MCP stdout/stderr exceeded total byte bound")
            if output:
                self._stdout_buffer.extend(block)

    def receive(self, expected_id: Any, method: str, timeout: float) -> dict[str, Any]:
        end = min(self.deadline, time.monotonic() + timeout)
        while True:
            line = self._take_response_line(method)
            if line is not None:
                try:
                    response = json.loads(line)
                except (ValueError, UnicodeDecodeError) as error:
                    raise CompatibilityError("MCP stdout contains malformed JSON") from error
                require(isinstance(response, dict), "MCP response is not an object")
                require(self._response_id_key(response.get("id")) == self._response_id_key(expected_id),
                        "MCP response correlation mismatch")
                self._response_arrival_ids.append(expected_id)
                return response
            require(self.process.poll() is None or bool(self.selector.get_map()),
                    "MCP process exited before its response")
            self._pump(end)

    def call(self, method: str, params: dict[str, Any], *, error: str | None = None) -> dict[str, Any]:
        require(len(self.requests) < MAXIMUM_CALLS_PER_PROCESS, "MCP call count exceeds bound")
        request_id = len(self.requests) + 1
        request = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        self.requests.append(request)
        self.send(request)
        response = self.receive(request_id, method, RESPONSE_SECONDS)
        self.responses.append(response)
        if method == "tools/call":
            return validate_tool_call_envelope(response, expected_error=error is not None,
                                               expected_code=error, expected_id=request_id)
        validate_endpoint_response(response, method, request_id)
        return response["result"]

    def tool(self, name: str, arguments: dict[str, Any], *, error: str | None = None) -> dict[str, Any]:
        return self.call("tools/call", {"name": name, "arguments": arguments}, error=error)

    def initialize(self) -> None:
        result = self.call("initialize", {
            "protocolVersion": SUPPORTED_PROTOCOL_VERSIONS[0], "capabilities": {},
            "clientInfo": {"name": "forge-memory-qualification", "version": "1"},
        })
        require(result.get("protocolVersion") == SUPPORTED_PROTOCOL_VERSIONS[0], "protocol negotiation changed")
        notification = {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}
        self.requests.append(notification)
        self.send(notification)
        self.call("tools/list", {})
        names = set(tool_map(self.responses[-1], "memory qualification"))
        require(LEGACY_TOOLS | PROJECT_TOOLS <= names, "memory tool inventory is incomplete")

    def stop(self, *, failed: bool = False) -> None:
        assert self.process.stdin and self.process.stdout and self.process.stderr
        try:
            if failed:
                terminate_process_group(self.process)
            else:
                self.process.stdin.close()
                end = min(self.deadline, time.monotonic() + SHUTDOWN_SECONDS)
                while self.selector.get_map() or self.process.poll() is None:
                    self._pump(end)
                require(not self._stdout_buffer.strip(), "unexpected trailing MCP stdout")
                require(self.process.returncode == 0, "MCP serve exited unsuccessfully")
        finally:
            if self.process.poll() is None:
                terminate_process_group(self.process)
            self.observation.update(ended_at=now(), exit_code=self.process.returncode,
                                    stdin=raw_artifact(bytes(self.raw_input)),
                                    stdout=raw_artifact(bytes(self.raw_output)),
                                    stderr=raw_artifact(bytes(self.raw_error)))
            self.selector.close()
            for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
                if not stream.closed:
                    stream.close()


def record_ids(result: dict[str, Any]) -> set[str]:
    records = result.get("records")
    require(isinstance(records, list) and type(result.get("count")) is int
            and result["count"] == len(records), "record count mismatch")
    ids = [item.get("id") for item in records if isinstance(item, dict)]
    require(len(ids) == len(records) and all(isinstance(item, str) and item for item in ids), "invalid record ids")
    require(len(set(ids)) == len(ids), "duplicate records in one page")
    return set(ids)


def root_bound(result: dict[str, Any], project: pathlib.Path) -> bool:
    roots = result.get("project_context", {}).get("authorization_roots")
    return isinstance(roots, list) and len(roots) == 1 and isinstance(roots[0], str) \
        and pathlib.Path(roots[0]).resolve(strict=True) == project.resolve(strict=True)


def read_export(path: pathlib.Path, root: pathlib.Path) -> tuple[bytes, dict[str, Any]]:
    require(path.resolve(strict=True).is_relative_to(root.resolve(strict=True)), "export escaped disposable fixture")
    require(path.is_file() and not path.is_symlink(), "export is not a regular fixture file")
    with path.open("rb") as stream:
        raw = stream.read(MAXIMUM_STREAM_BYTES + 1)
    require(len(raw) <= MAXIMUM_STREAM_BYTES, "export exceeds fixture byte bound")
    value = json.loads(raw)
    require(isinstance(value, dict) and isinstance(value.get("records"), list), "malformed export")
    # Foundation JSONSerialization escapes slashes; fixture content intentionally
    # uses no slashes so this exact canonical checksum is portable.
    require(value.get("checksum") == normalized_hash(value["records"]), "export record checksum mismatch")
    return raw, value


def exercise(binary: pathlib.Path, root: pathlib.Path, report: dict[str, Any]) -> None:
    home, project_a, project_b = [root / name for name in ("home", "project-a", "project-b")]
    for path in (home, project_a, project_b):
        path.mkdir(mode=0o700)
    configure_allowed_roots(home, [project_a, project_b])
    report["fixture"] = {"root": str(root), "home": str(home), "projects": [str(project_a), str(project_b)],
                         "configuration": json.loads((home / "config.json").read_bytes()),
                         "setup_scope": "supported config.json allowed_roots in disposable home; no native picker"}
    deadline = time.monotonic() + MAXIMUM_MATRIX_SECONDS
    active: ObservedMCPProcess | None = None

    def start(label: str) -> ObservedMCPProcess:
        nonlocal active
        observation: dict[str, Any] = {}
        report["processes"].append(observation)
        active = ObservedMCPProcess(binary, home, label, deadline, observation)
        active.initialize()
        return active

    def stop() -> None:
        nonlocal active
        assert active
        process, active = active, None
        process.stop()

    def check(name: str, condition: bool) -> None:
        require(condition, name)
        assert active
        report["observations"].append({"postcondition": name,
                                       "process_index": len(report["processes"]) - 1,
                                       "through_response_id": active.responses[-1]["id"]})

    try:
        first = start("project-a-create")
        a = first.tool("project_memory.initialize", {"project_path": str(project_a)})
        aid = a["project_id"]
        uuid.UUID(aid)
        check("project_a_root_generation_bound", a.get("project_context_attached") is True
              and root_bound(a, project_a)
              and isinstance(a.get("project_generation"), int) and a["project_generation"] > 0)
        key, body = "qualification-memory", "durable legacy fixture body"
        first.tool("memory_set", {"key": key, "body": "initial body", "tags": ["fixture"]})
        check("legacy_create_readback", first.tool("memory_get", {"key": key}).get("body") == "initial body")
        first.tool("memory_set", {"key": key, "body": body, "tags": ["fixture", "updated"]})
        notes = first.tool("memory_list", {"prefix": key, "include_body": True, "limit": 2})["notes"]
        check("legacy_update_list_readback", len(notes) == 1 and notes[0].get("body") == body
              and set(notes[0].get("tags", [])) == {"fixture", "updated"})
        notes = first.tool("memory_search", {"query": body, "include_body": True, "limit": 2})["notes"]
        check("legacy_search_readback", len(notes) == 1 and notes[0].get("key") == key and notes[0].get("body") == body)
        write = {"project_id": aid, "kind": "fact", "title": "Qualification alpha",
                 "summary": "bounded memory marker alpha", "body": "initial project body",
                 "tags": ["fixture"], "idempotency_key": "qualification-alpha"}
        inserted = first.tool("project_memory.remember", write)
        rid = inserted["record_id"]
        duplicate = first.tool("project_memory.remember", write)
        check("project_create_idempotency", inserted.get("disposition") == "inserted"
              and duplicate.get("disposition") == "deduplicated" and duplicate.get("record_id") == rid)
        updated = first.tool("project_memory.update", {"project_id": aid, "id": rid,
                            "expected_version": 1, "body": "updated project body"})
        check("project_update_version", updated["record"].get("version") == 2
              and updated["record"].get("body") == "updated project body")
        first.tool("project_memory.update", {"project_id": aid, "id": rid,
                   "expected_version": 1, "body": "must not commit"}, error="conflict")
        got = first.tool("project_memory.get", {"project_id": aid, "id": rid, "include_body": True})
        check("project_conflicting_update_no_effect", record_ids(got) == {rid}
              and got["records"][0].get("body") == "updated project body")
        batch = first.tool("project_memory.remember_batch", {"project_id": aid, "items": [
            {"kind": "fact", "title": "Qualification " + item, "summary": "bounded memory marker " + item}
            for item in ("beta", "gamma")]})
        bid = batch["results"][0]["record_id"]
        ids = {rid} | {item["record_id"] for item in batch["results"]}
        check("project_batch_inserted", batch.get("count") == 2 and len(ids) == 3
              and all(item.get("disposition") == "inserted" for item in batch["results"]))
        first.tool("project_memory.remember_batch", {"project_id": aid, "items": [
            {"kind": "fact", "title": "must not commit", "summary": "invalid batch first item"},
            {"kind": "fact", "title": "missing summary"}]}, error="invalid_request")
        check("project_invalid_batch_no_partial_commit", first.tool("project_memory.status", {
            "project_id": aid}).get("record_count") == 3)
        page1 = first.tool("project_memory.search", {"project_id": aid, "query": "bounded", "limit": 2,
                           "maximum_response_bytes": 4096})
        page2 = first.tool("project_memory.search", {"project_id": aid, "query": "bounded", "limit": 2,
                           "maximum_response_bytes": 4096, "cursor": page1.get("next_cursor")})
        check("project_search_bounded_pagination", len(record_ids(page1)) == 2 and len(record_ids(page2)) == 1
              and not record_ids(page1) & record_ids(page2) and record_ids(page1) | record_ids(page2) == ids
              and page1.get("truncated") is True and page2.get("truncated") is False
              and page2.get("next_cursor") is None
              and all(page.get("encoded_bytes", 99999) <= 4096 and len(canonical_bytes(page)) <= 4096
                      for page in (page1, page2)))
        check("project_list_readback", record_ids(first.tool("project_memory.list_recent", {
            "project_id": aid, "limit": 10, "include_body": True, "maximum_response_bytes": 8192})) == ids)
        link = {"project_id": aid, "source_id": rid, "target_id": bid, "relation": "supports"}
        linked = first.tool("project_memory.link", link)
        linked_twice = first.tool("project_memory.link", link)
        check("project_link_idempotency", linked.get("disposition") == "inserted"
              and linked_twice.get("disposition") == "deduplicated")
        exported = first.tool("project_memory.export", {"project_id": aid})
        export_path = pathlib.Path(exported["artifact"])
        export_raw, export_value = read_export(export_path, root)
        report["exports"].append({"path": str(export_path), **raw_artifact(export_raw)})
        check("project_export_checksum_and_contents", exported.get("checksum") == export_value["checksum"]
              and exported.get("record_count") == 3 and export_value.get("project_id") == aid
              and {item["id"] for item in export_value["records"]} == ids)
        status = first.tool("project_memory.status", {"project_id": aid})
        check("project_status_integrity", status.get("integrity") == "ok" and status.get("record_count") == 3)
        stop()

        second = start("project-b-denial-and-import")
        b = second.tool("project_memory.initialize", {"project_path": str(project_b)})
        bpid = b["project_id"]
        check("distinct_project_identity", bpid != aid and root_bound(b, project_b))
        check("project_b_cannot_read_a_record", not record_ids(second.tool("project_memory.get", {"project_id": bpid, "id": rid})))
        denied = {
            "initialize": {"project_path": str(project_a)}, "remember": write,
            "remember_batch": {"project_id": aid, "items": [{"kind": "fact", "title": "denied", "summary": "denied"}]},
            "search": {"project_id": aid, "query": "bounded"}, "get": {"project_id": aid, "id": rid},
            "update": {"project_id": aid, "id": rid, "expected_version": 2, "body": "denied"},
            "forget": {"project_id": aid, "id": rid}, "list_recent": {"project_id": aid},
            "link": link, "export": {"project_id": aid},
            "import": {"project_id": aid, "artifact": str(export_path), "preview": False},
            "status": {"project_id": aid},
        }
        for tool, arguments in denied.items():
            second.tool("project_memory." + tool, arguments, error="project_scope_mismatch")
            check("project_b_cross_project_" + tool + "_denied", True)
        check("legacy_home_scope_preserved_across_project_binding", second.tool("memory_get", {"key": key}).get("body") == body)
        second.tool("project_memory.import", {"project_id": bpid, "artifact": str(export_path), "preview": False,
                                              "merge_policy": "merge"}, error="project_scope_mismatch")
        check("project_import_foreign_path_denied", True)
        b_export = second.tool("project_memory.export", {"project_id": bpid})
        b_export_path = pathlib.Path(b_export["artifact"])
        read_export(b_export_path, root)
        copied_export = b_export_path.parent / "qualification-import.json"
        atomic_write(copied_export, export_raw)
        report["fixture"]["import_setup"] = {"source": str(export_path), "destination": str(copied_export),
                                               "sha256": sha256_bytes(export_raw),
                                               "method": "copy actual checksummed export into target project exports directory"}
        corrupt_export = b_export_path.parent / "qualification-corrupt-import.json"
        corrupt_value = json.loads(export_raw)
        corrupt_value["records"][0]["summary"] = "corrupt checksum fixture"
        atomic_write(corrupt_export, output_bytes(corrupt_value))
        second.tool("project_memory.import", {"project_id": bpid, "artifact": str(corrupt_export),
                    "preview": False, "merge_policy": "merge"}, error="integrity_failure")
        check("project_import_checksum_rejection_no_mutation", second.tool("project_memory.status", {
            "project_id": bpid}).get("record_count") == 0)
        second.tool("project_memory.import", {"project_id": bpid, "artifact": str(copied_export)}, error="project_scope_mismatch")
        check("project_import_requires_explicit_merge", True)
        preview = second.tool("project_memory.import", {"project_id": bpid, "artifact": str(copied_export),
                             "preview": True, "merge_policy": "merge"})
        status = second.tool("project_memory.status", {"project_id": bpid})
        check("project_import_preview_no_mutation", preview.get("preview") is True and preview.get("importable_count") == 3
              and status.get("record_count") == 0)
        imported = second.tool("project_memory.import", {"project_id": bpid, "artifact": str(copied_export),
                              "preview": False, "merge_policy": "merge"})
        imported_ids = {item["record_id"] for item in imported["results"]}
        check("project_import_commit", imported.get("count") == 3 and len(imported_ids) == 3 and not imported_ids & ids
              and all(item.get("disposition") == "inserted" for item in imported["results"]))
        stop()

        third = start("project-a-restart-delete")
        restarted = third.tool("project_memory.initialize", {"project_path": str(project_a)})
        check("project_identity_generation_survive_restart", restarted.get("project_id") == aid
              and restarted.get("project_generation") == a.get("project_generation")
              and root_bound(restarted, project_a))
        readback = third.tool("project_memory.get", {"project_id": aid, "ids": sorted(ids), "include_body": True})
        check("project_restart_and_denied_mutations_readback", record_ids(readback) == ids
              and next(item for item in readback["records"] if item["id"] == rid).get("body") == "updated project body")
        check("project_link_survives_restart", third.tool("project_memory.link", link).get("disposition") == "deduplicated")
        check("legacy_survives_restart", third.tool("memory_get", {"key": key}).get("body") == body)
        deleted = third.tool("memory_delete", {"key": key})
        check("legacy_delete_readback", deleted.get("deleted") is True and deleted.get("existed") is True
              and third.tool("memory_get", {"key": key}).get("found") is False)
        forgotten = third.tool("project_memory.forget", {"project_id": aid, "id": bid})
        check("project_forget_readback", forgotten.get("disposition") == "tombstoned"
              and not record_ids(third.tool("project_memory.get", {"project_id": aid, "id": bid})))
        stop()

        fourth = start("project-b-import-restart")
        b_restart = fourth.tool("project_memory.initialize", {"project_path": str(project_b)})
        got = fourth.tool("project_memory.get", {"project_id": bpid, "ids": sorted(imported_ids), "include_body": True})
        check("project_import_survives_restart", b_restart.get("project_id") == bpid and record_ids(got) == imported_ids
              and {item["title"] for item in got["records"]} == {item["title"] for item in export_value["records"]}
              and any(item.get("body") == "updated project body" for item in got["records"]))
        check("legacy_delete_survives_restart", fourth.tool("memory_get", {"key": key}).get("found") is False)
        stop()

        fifth = start("project-a-tombstone-restart")
        fifth.tool("project_memory.initialize", {"project_path": str(project_a)})
        got = fifth.tool("project_memory.list_recent", {"project_id": aid, "limit": 10})
        status = fifth.tool("project_memory.status", {"project_id": aid})
        check("project_tombstone_survives_restart", record_ids(got) == ids - {bid}
              and status.get("integrity") == "ok" and status.get("record_count") == 2 and status.get("tombstone_count") == 1)
        stop()
    finally:
        if active is not None:
            active.stop(failed=True)


def capture(repository: pathlib.Path, binary: pathlib.Path, *, app: pathlib.Path | None = None,
            evidence_id: str | None = None, challenge_nonce: str | None = None) -> dict[str, Any]:
    repository, binary = repository.resolve(strict=True), binary.resolve(strict=True)
    require(binary.is_file() and os.access(binary, os.X_OK), "CLI is not executable")
    if app is not None:
        app = app.resolve(strict=True)
        require(binary == (app / "Contents/Helpers/forge-conductor").resolve(strict=True)
                and binary.is_relative_to(app), "CLI is not the app's embedded helper")
    report: dict[str, Any] = {
        "schema_version": 1, "kind": "p10-mcp-memory-observations", "status": "failed",
        "evidence_id": evidence_id, "challenge_nonce": challenge_nonce,
        "started_at": now(), "maximum_matrix_seconds": MAXIMUM_MATRIX_SECONDS,
        "binary": {"path": str(binary), "sha256": sha256_file(binary), "bytes": binary.stat().st_size},
        "app_path": str(app) if app else None,
        "binary_origin": "native_embedded_cli" if app else "explicit_component_binary",
        "source": {"git": git_source_state(repository), "manifest": source_manifest(repository)},
        "native_onboarding_assessed": False, "installation_assessed": False,
        "signing_assessed": False, "migration_assessed": False, "build_provenance_assessed": False,
        "accepted_p10_assertions": [], "processes": [], "observations": [], "exports": [],
    }
    start = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="forge-p10-memory-") as directory:
        root = pathlib.Path(directory).resolve(strict=True)
        try:
            exercise(binary, root, report)
            require(sha256_file(binary) == report["binary"]["sha256"], "CLI changed during qualification")
            require(source_manifest(repository) == report["source"]["manifest"], "source changed during qualification")
            report["status"] = "passed"
        except (CompatibilityError, OSError, ValueError, KeyError, TypeError) as error:
            report["failure"] = str(error)[:2000]
    report.update(ended_at=now(), duration_seconds=round(time.monotonic() - start, 4),
                  fixture_removed=not root.exists(), observed_postcondition_count=len(report["observations"]))
    report["successful_tool_members"] = sorted({
        request["params"]["name"]
        for process in report["processes"]
        for request in process.get("requests", [])
        if request.get("method") == "tools/call"
        and any(response.get("id") == request["id"]
                and response.get("result", {}).get("isError") is False
                for response in process.get("responses", []))
    })
    if not report["fixture_removed"]:
        report["status"] = "failed"
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--app", type=pathlib.Path, help="Normal native app containing Contents/Helpers/forge-conductor")
    source.add_argument("--binary", type=pathlib.Path, help="Component-only validation; does not claim native bundle execution")
    parser.add_argument("--repository", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=pathlib.Path, required=True, help="Supporting raw artifact for record_command.py --artifact")
    args = parser.parse_args()
    binary = args.binary or args.app / "Contents/Helpers/forge-conductor"
    output = args.output.resolve()
    require(output != binary.resolve(), "output would overwrite CLI")
    require(args.app is None or not output.is_relative_to(args.app.resolve()), "output must be outside the app")
    result = capture(args.repository, binary, app=args.app, evidence_id=os.environ.get("FORGE_EVIDENCE_ID"),
                     challenge_nonce=os.environ.get("FORGE_QUALIFICATION_CHALLENGE_NONCE"))
    atomic_write(output, output_bytes(result))
    print(json.dumps({"status": result["status"], "observed_postconditions": result["observed_postcondition_count"],
                      "output": str(output), "failure": result.get("failure")}))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
