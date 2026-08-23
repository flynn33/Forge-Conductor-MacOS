#!/usr/bin/env python3
"""Process-level MCP continuity lifecycle and restart conformance."""

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


class MCPProcess:
    def __init__(self, binary: pathlib.Path, home: pathlib.Path) -> None:
        environment = dict(os.environ)
        environment.update(
            FORGE_CONDUCTOR_HOME=str(home),
            FORGE_MCP_ROLE="primary",
            FORGE_DEPLOYMENT_ID="p08-conformance",
        )
        self.process = subprocess.Popen(
            [str(binary), "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=environment, text=True, bufsize=1,
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
                response = json.loads(self.process.stdout.readline())
                if response.get("id") == request_id:
                    return response
            raise TimeoutError(self._failure(f"timed out waiting for {method}"))
        finally:
            selector.close()

    def tool_result(self, name: str, arguments: dict) -> dict:
        response = self.call("tools/call", {"name": name, "arguments": arguments})
        if "error" in response:
            raise AssertionError(response)
        return response["result"]

    def tool(self, name: str, arguments: dict) -> dict:
        result = self.tool_result(name, arguments)
        if result.get("isError"):
            raise AssertionError(result)
        return result["structuredContent"]

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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    require(binary.is_file() and os.access(binary, os.X_OK), f"binary is not executable: {binary}")

    root = pathlib.Path(tempfile.mkdtemp(prefix="forge-p08-conformance-"))
    home = root / "home"
    project = root / "project"
    project.mkdir(parents=True)
    transcript: list[dict] = []
    first = MCPProcess(binary, home)
    try:
        initialized = first.call("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}})
        transcript.append(initialized)
        listed = first.call("tools/list", {})
        tools = {tool["name"]: tool for tool in listed["result"]["tools"]}
        continuity_tools = {
            "continuity.checkpoint", "continuity.prepare_handoff",
            "continuity.get_pending_handoff", "continuity.acknowledge_handoff",
            "continuity.resume", "continuity.status", "continuity.request_rollover",
        }
        require(continuity_tools <= set(tools), "continuity tool inventory is incomplete")
        require(
            all(tools[name]["inputSchema"]["type"] == "object" for name in continuity_tools),
            "continuity tool schema mismatch",
        )
        scope = first.tool("project_memory.initialize", {"project_path": str(project)})
        project_id = scope["project_id"]
        prepared = first.tool(
            "continuity.request_rollover",
            {
                "project_id": project_id,
                "predecessor_session_id": "process-predecessor",
                "mission": "Continue process-level repair",
                "phase_id": "P08",
                "work_item_id": "P08-07",
                "next_actions": ["Recover the pending handoff", "Acknowledge the successor"],
            },
        )
        require(prepared["disposition"] == "memory_only_handoff_ready", "capability fallback mismatch")
        operation = prepared["operation"]
        handoff = prepared["handoff"]
        require(operation["state"] == "checkpointPersisted", "checkpoint was not persisted")
        transcript.append({"prepared": prepared})
    finally:
        first.close()

    second = MCPProcess(binary, home)
    try:
        second.call("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}})
        reopened = second.tool("project_memory.initialize", {"project_path": str(project)})
        require(reopened["project_id"] == project_id, "project identity changed after restart")
        pending = second.tool("continuity.get_pending_handoff", {"project_id": project_id})
        require(pending["found"] and pending["handoff"]["handoff_id"] == handoff["handoff_id"], "handoff was not durable")

        invalid = second.tool_result(
            "continuity.acknowledge_handoff",
            {
                "project_id": project_id, "operation_id": operation["operation_id"],
                "handoff_id": handoff["handoff_id"], "successor_session_id": "wrong",
                "adapter_id": "wrong-adapter",
            },
        )
        require(invalid["isError"] and invalid["structuredContent"]["code"] == "conflict", "exact-match rejection failed")
        still_pending = second.tool("continuity.get_pending_handoff", {"project_id": project_id})
        require(still_pending["operation"]["state"] == "checkpointPersisted", "rejected acknowledgment mutated state")

        acknowledgement = {
            "project_id": project_id, "operation_id": operation["operation_id"],
            "handoff_id": handoff["handoff_id"], "successor_session_id": "process-successor",
            "adapter_id": "external-mcp",
        }
        acknowledged = second.tool("continuity.acknowledge_handoff", acknowledgement)
        repeated = second.tool("continuity.acknowledge_handoff", acknowledgement)
        require(acknowledged["operation"]["state"] == "successorAcknowledged", "acknowledgment failed")
        require(repeated["operation"]["state"] == "successorAcknowledged", "acknowledgment replay failed")
        sealed = second.tool(
            "continuity.resume", {"project_id": project_id, "operation_id": operation["operation_id"]}
        )
        require(sealed["operation"]["state"] == "predecessorSealed", "rollover did not seal")
        status = second.tool("continuity.status", {"project_id": project_id})
        require(status["active_session_id"] == "process-successor", "active session was not swapped")
        transcript.append({
            "restart_pending": pending, "rejected_acknowledgement": invalid,
            "acknowledged": acknowledged, "replayed_acknowledgement": repeated,
            "sealed": sealed, "status": status,
        })
    finally:
        second.close()

    output = {
        "ok": True,
        "binary": str(binary),
        "project_id": project_id,
        "checks": [
            "tool_inventory", "tool_schemas", "memory_only_capability_fallback",
            "durable_handoff_restart", "exact_acknowledgement_rejection",
            "rejected_acknowledgement_no_mutation", "idempotent_acknowledgement",
            "predecessor_seal", "active_session_swap",
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
