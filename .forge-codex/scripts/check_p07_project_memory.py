#!/usr/bin/env python3
"""Process-level stdio conformance and restart test for project memory MCP."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import selectors
import shutil
import subprocess
import sys
import tempfile
import time


CONFIG_SCHEMA_VERSION = 2
PROJECT_MEMORY_CAPABILITY_VERSION = 1
PROJECT_MEMORY_SCHEMA_VERSION = 2


class MCPProcess:
    def __init__(self, binary: pathlib.Path, home: pathlib.Path) -> None:
        environment = dict(os.environ)
        environment.update(
            FORGE_CONDUCTOR_HOME=str(home),
            FORGE_MCP_ROLE="primary",
            FORGE_DEPLOYMENT_ID="p07-conformance",
        )
        self.process = subprocess.Popen(
            [str(binary), "serve"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            text=True,
            bufsize=1,
        )
        self.next_id = 1

    def call(self, method: str, params: dict | None = None, timeout: float = 8) -> dict:
        request_id = self.next_id
        self.next_id += 1
        request = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            request["params"] = params
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        self.process.stdin.flush()
        selector = selectors.DefaultSelector()
        assert self.process.stdout is not None
        selector.register(self.process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + timeout
        try:
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    raise RuntimeError(self._failure("server exited before response"))
                events = selector.select(min(0.1, deadline - time.monotonic()))
                if not events:
                    continue
                line = self.process.stdout.readline()
                if not line:
                    continue
                response = json.loads(line)
                if response.get("id") == request_id:
                    return response
            raise TimeoutError(self._failure(f"timed out waiting for {method}"))
        finally:
            selector.close()

    def tool(self, name: str, arguments: dict) -> dict:
        response = self.call("tools/call", {"name": name, "arguments": arguments})
        if "error" in response:
            raise AssertionError(response)
        result = response["result"]
        if result.get("isError"):
            raise AssertionError(result)
        return result["structuredContent"]

    def cancel_next(self) -> dict:
        request_id = self.next_id
        assert self.process.stdin is not None
        notification = {
            "jsonrpc": "2.0", "method": "notifications/cancelled",
            "params": {"requestId": request_id, "reason": "conformance"},
        }
        self.process.stdin.write(json.dumps(notification, separators=(",", ":")) + "\n")
        self.process.stdin.flush()
        return self.call("ping", {})

    def close(self) -> None:
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
        for stream in (self.process.stdout, self.process.stderr):
            if stream and not stream.closed:
                stream.close()

    def _failure(self, message: str) -> str:
        error = ""
        if self.process.stderr and self.process.poll() is not None:
            error = self.process.stderr.read()[-2000:]
        return f"{message}; stderr={error}"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def atomic_write_private_json(path: pathlib.Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = pathlib.Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            descriptor = -1
            json.dump(payload, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary.exists():
            temporary.unlink()


def configure_allowed_roots(home: pathlib.Path, roots: list[pathlib.Path]) -> None:
    require(bool(roots), "project-memory fixture requires at least one trusted root")
    resolved = [root.resolve(strict=True) for root in roots]
    require(
        all(root.is_dir() for root in resolved),
        "project-memory fixture roots must be existing directories",
    )
    normalized = [str(root) for root in resolved]
    require(
        len(normalized) == len(set(normalized)),
        "project-memory fixture roots contain duplicates",
    )
    atomic_write_private_json(
        home / "config.json",
        {
            "config_schema_version": CONFIG_SCHEMA_VERSION,
            "allowed_roots": normalized,
        },
    )


def validate_project_memory_capability(capabilities: object) -> dict:
    require(isinstance(capabilities, dict), "initialize capabilities are missing")
    project_memory = capabilities.get("projectMemory")
    require(isinstance(project_memory, dict), "missing project memory capability")
    require(
        project_memory.get("capabilityVersion") == PROJECT_MEMORY_CAPABILITY_VERSION,
        "project memory capability version mismatch",
    )
    require(
        project_memory.get("schemaVersion") == PROJECT_MEMORY_SCHEMA_VERSION,
        "project memory schema version mismatch",
    )
    require(isinstance(project_memory.get("limits"), dict), "project memory limits are missing")
    return project_memory


def validate_project_memory_scope(scope: object) -> dict:
    require(isinstance(scope, dict), "project memory initialization result is missing")
    require(scope.get("ok") is True, "project memory initialization did not succeed")
    require(
        scope.get("capability_version") == PROJECT_MEMORY_CAPABILITY_VERSION,
        "project memory initialization capability version mismatch",
    )
    require(
        scope.get("schema_version") == PROJECT_MEMORY_SCHEMA_VERSION,
        "project memory initialization schema version mismatch",
    )
    return scope


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    require(binary.is_file() and os.access(binary, os.X_OK), f"binary is not executable: {binary}")

    root = pathlib.Path(tempfile.mkdtemp(prefix="forge-p07-conformance-"))
    home = root / "home"
    project = root / "project"
    project.mkdir(parents=True)
    configure_allowed_roots(home, [project])
    transcript: list[dict] = []
    first = MCPProcess(binary, home)
    try:
        initialized = first.call(
            "initialize",
            {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "p07", "version": "1"}},
        )
        transcript.append(initialized)
        capabilities = initialized["result"]["capabilities"]
        validate_project_memory_capability(capabilities)

        listed = first.call("tools/list", {})
        transcript.append(listed)
        tools = {tool["name"]: tool for tool in listed["result"]["tools"]}
        legacy = {"memory_set", "memory_get", "memory_list", "memory_delete", "memory_search"}
        project_tools = {
            "project_memory.initialize", "project_memory.remember", "project_memory.remember_batch",
            "project_memory.search", "project_memory.get", "project_memory.update",
            "project_memory.forget", "project_memory.list_recent", "project_memory.link",
            "project_memory.export", "project_memory.import", "project_memory.status",
        }
        require(legacy | project_tools <= set(tools), "tool inventory is incomplete")
        require(all(tools[name]["inputSchema"]["type"] == "object" for name in project_tools), "tool schema mismatch")

        scope = validate_project_memory_scope(first.tool(
            "project_memory.initialize",
            {"project_path": str(project), "idempotency_key": "scope-v2"},
        ))
        transcript.append({"tool": "project_memory.initialize", "result": scope})
        project_id = scope["project_id"]
        remembered = first.tool(
            "project_memory.remember",
            {
                "project_id": project_id,
                "kind": "recovery_checkpoint",
                "title": "Executable conformance",
                "summary": "Durable process boundary api_key=secret-value",
                "body": "Authorization: Bearer abcdefghijklmnopqrstuvwxyz",  # Example credential fixture.
                "tags": ["p07", "process"],
                "idempotency_key": "process-checkpoint-v1",
            },
        )
        transcript.append({"tool": "project_memory.remember", "result": remembered})
        require(remembered["disposition"] == "inserted", "record was not inserted")
        searched = first.tool(
            "project_memory.search",
            {"project_id": project_id, "query": "conformance", "include_body": True, "maximum_response_bytes": 4096},
        )
        transcript.append({"tool": "project_memory.search", "result": searched})
        require(searched["count"] == 1, "inserted record was not searchable")
        record = searched["records"][0]
        require("secret-value" not in record["summary"], "summary secret was not redacted")
        require("abcdefghijklmnopqrstuvwxyz" not in record["body"], "body credential was not redacted")
        status = first.tool("project_memory.status", {"project_id": project_id})
        transcript.append({"tool": "project_memory.status", "result": status})
        require(status["integrity"] == "ok" and status["record_count"] == 1, "status health mismatch")
        require(status.get("schema_version") == PROJECT_MEMORY_SCHEMA_VERSION, "status schema version mismatch")

        batch = first.tool(
            "project_memory.remember_batch",
            {
                "project_id": project_id,
                "items": [
                    {"kind": "fact", "title": f"Page {index}", "summary": f"pagination marker {index}"}
                    for index in range(3)
                ],
            },
        )
        require(batch["count"] == 3, "batch conformance failed")
        page_one = first.tool(
            "project_memory.search", {"project_id": project_id, "query": "pagination", "limit": 1}
        )
        require(page_one["count"] == 1 and page_one["truncated"], "first pagination frame failed")
        page_two = first.tool(
            "project_memory.search",
            {"project_id": project_id, "query": "pagination", "limit": 1, "cursor": page_one["next_cursor"]},
        )
        require(page_two["count"] == 1, "second pagination frame failed")
        transcript.append({"pagination": [page_one, page_two]})

        invalid = first.call(
            "tools/call",
            {"name": "project_memory.get", "arguments": {"project_id": "not-a-uuid", "id": "missing"}},
        )
        invalid_content = invalid["result"]["structuredContent"]
        require(invalid["result"]["isError"] and invalid_content["code"] == "invalid_request", "typed error failed")
        transcript.append({"typed_error": invalid})

        cancelled = first.cancel_next()
        require(cancelled.get("error", {}).get("code") == -32800, "cancellation response failed")
        transcript.append({"cancellation": cancelled})
    finally:
        first.close()

    second = MCPProcess(binary, home)
    try:
        restarted = second.call("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}})
        validate_project_memory_capability(restarted["result"]["capabilities"])
        transcript.append({"restart_initialize": restarted})
        reopened = validate_project_memory_scope(
            second.tool("project_memory.initialize", {"project_path": str(project)})
        )
        require(reopened["project_id"] == project_id, "project identity changed after restart")
        durable = second.tool("project_memory.search", {"project_id": project_id, "query": "conformance"})
        transcript.append({"restart_search": durable})
        require(durable["count"] == 1, "record did not survive process restart")
    finally:
        second.close()

    output = {
        "ok": True,
        "binary": str(binary),
        "config_schema_version": CONFIG_SCHEMA_VERSION,
        "project_memory_schema_version": PROJECT_MEMORY_SCHEMA_VERSION,
        "project_id": project_id,
        "checks": [
            "trusted_root_policy", "schema_v2", "initialize", "tools_list", "legacy_compatibility", "tool_schemas", "remember",
            "redaction", "search", "status", "pagination", "typed_error", "cancellation",
            "process_restart_durability",
        ],
        "transcript": transcript,
    }
    serialized = json.dumps(output, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(serialized)
    sys.stdout.write(serialized)
    shutil.rmtree(root, ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
